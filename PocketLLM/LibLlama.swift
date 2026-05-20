import Foundation
import Foundation
import llama

#if canImport(UIKit)
import UIKit
#endif

enum LlamaError: Error {
    case couldNotInitializeContext
    case modelLoadFailed
    case decodeFailed(Int32)
    case promptTooLong(promptTokens: Int32, contextLength: Int32)
    case visionNotAvailable
    case imageLoadFailed
    case memoryOverflow
    case mtmdInitFailed
    case mtmdTokenizeFailed(Int32)
    case mtmdEvalFailed(Int32)
}

extension LlamaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .couldNotInitializeContext:
            return "Failed to initialize llama context."
        case .modelLoadFailed:
            return "模型加载失败。请稍等片刻后重试，或先清空上下文再加载。"
        case .decodeFailed(let code):
            return "llama_decode failed (code: \(code))."
        case .promptTooLong(let promptTokens, let contextLength):
            return "Prompt too long (\(promptTokens) tokens) for context length \(contextLength). Clear chat or increase context length."
        case .visionNotAvailable:
            return "Vision is not available. Select an mmproj model and try again."
        case .imageLoadFailed:
            return "Failed to load the selected image."
        case .memoryOverflow:
            return "内存溢出，请尝试调整图片分辨率设置"
        case .mtmdInitFailed:
            return "Failed to initialize multimodal context (mmproj)."
        case .mtmdTokenizeFailed(let code):
            return "Failed to tokenize multimodal prompt (code: \(code))."
        case .mtmdEvalFailed(let code):
            return "Failed to evaluate multimodal prompt (code: \(code))."
        }
    }
}

private enum LlamaBackend {
    nonisolated(unsafe) private static let initialized: Void = {
        llama_backend_init()
    }()

    nonisolated static func ensureInitialized() {
        _ = initialized
    }
}

actor LlamaContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer
    private var mtmd: OpaquePointer?
    private var sampling: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var batchCapacity: Int32
    private var tokens_list: [llama_token]
    var is_done: Bool = false

    /// This variable is used to store temporarily invalid cchars
    private var temporary_invalid_cchars: [CChar]

    var n_len: Int32 = 1024
    var n_cur: Int32 = 0
    var n_decode: Int32 = 0

    private var maxNewTokensRemaining: Int32 = 0
    private let imageEvalBatchCap: Int32

    private var shouldStop: Bool = false
    private var isClosed = false

    private func batchClear() {
        batch.n_tokens = 0
    }

    private func batchAdd(_ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
        batch.token[Int(batch.n_tokens)] = id
        batch.pos[Int(batch.n_tokens)] = pos
        batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
        for i in 0..<seq_ids.count {
            guard let seqPtr = batch.seq_id[Int(batch.n_tokens)] else {
                // llama.cpp stores a null sentinel at seq_id[n_tokens_alloc]
                fatalError("llama_batch overflow: capacity=\(batchCapacity), index=\(batch.n_tokens)")
            }
            seqPtr[Int(i)] = seq_ids[i]
        }
        batch.logits[Int(batch.n_tokens)] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    init(model: OpaquePointer, context: OpaquePointer, mtmd: OpaquePointer?, contextLength: Int32, temperature: Float, topK: Int32, topP: Float, repeatPenalty: Float, presencePenalty: Float, frequencyPenalty: Float, seed: UInt32, imageEvalBatchCap: Int32) {
        self.model = model
        self.context = context
        self.mtmd = mtmd
        self.tokens_list = []
        self.batchCapacity = max(512, contextLength)
        self.batch = llama_batch_init(self.batchCapacity, 0, 1)
        self.imageEvalBatchCap = max(1, imageEvalBatchCap)
        self.temporary_invalid_cchars = []
        self.vocab = llama_model_get_vocab(model)

        self.sampling = Self.makeSampler(
            temperature: temperature,
            topK: topK,
            topP: topP,
            repeatPenalty: repeatPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed
        )
    }

    deinit {
        closeResources()
    }

    private func closeResources() {
        guard isClosed == false else { return }
        isClosed = true
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        if let mtmd {
            mtmd_free(mtmd)
            self.mtmd = nil
        }
        llama_free(context)
        llama_model_free(model)
    }

    func close() {
        closeResources()
    }

    static func create_context(path: String, contextLength: Int32, temperature: Float, topK: Int32, topP: Float, repeatPenalty: Float, presencePenalty: Float, frequencyPenalty: Float, mmprojPath: String?, seed: UInt32, imageMaxSlices: Int32, useGPU: Bool, batchSize: Int32, ubatchSize: Int32, imageEvalBatchSize: Int32, forceMMProjCPU: Bool) throws -> LlamaContext {
        LlamaBackend.ensureInitialized()
        var model_params = llama_model_default_params()

#if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
#else
        model_params.n_gpu_layers = useGPU ? 999 : 0
#endif
        model_params.use_mmap = true
        let model: OpaquePointer? = llama_model_load_from_file(path, model_params)
        var context: OpaquePointer?
        var mtmdCtx: OpaquePointer?
        var ownershipTransferred = false

        defer {
            if ownershipTransferred == false {
                if let mtmdCtx {
                    mtmd_free(mtmdCtx)
                }
                if let context {
                    llama_free(context)
                }
                if let model {
                    llama_model_free(model)
                }
            }
        }

        guard let model else {
            print("Could not load model at \(path)")
            throw LlamaError.modelLoadFailed
        }

        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        print("Using \(n_threads) threads")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = UInt32(max(256, contextLength))
        let safeBatchSize = UInt32(max(256, min(1024, batchSize)))
        let safeUbatchSize = UInt32(max(256, min(Int32(safeBatchSize), ubatchSize)))
        ctx_params.n_batch = safeBatchSize
        ctx_params.n_ubatch = safeUbatchSize
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        print("llama context params: n_ctx=\(ctx_params.n_ctx), n_batch=\(ctx_params.n_batch), n_ubatch=\(ctx_params.n_ubatch), useGPU=\(useGPU)")

        context = llama_init_from_model(model, ctx_params)
        guard let context else {
            print("Could not load context!")
            throw LlamaError.couldNotInitializeContext
        }

        if let mmprojPath {
            var mparams = mtmd_context_params_default()
            let modelFilename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            let useCPUForMMProj = forceMMProjCPU || !useGPU || modelFilename.contains("minicpm-v-4_5")

            // MiniCPM-V 4.5 projector is too large for stable Metal allocation on iPhone.
            // MiniCPM-V 4.6 is designed for mobile and is much faster with the projector on GPU.
            mparams.use_gpu = !useCPUForMMProj
            mparams.print_timings = false
            mparams.n_threads = Int32(n_threads)
            mparams.image_max_slices = max(1, min(9, imageMaxSlices))
            print("mtmd params: image_max_slices=\(mparams.image_max_slices), mmprojGPU=\(mparams.use_gpu), mmproj=\(URL(fileURLWithPath: mmprojPath).lastPathComponent)")
            mtmdCtx = mtmd_init_from_file(mmprojPath, model, mparams)
            if mtmdCtx == nil, !useCPUForMMProj {
                mparams.use_gpu = false
                mtmdCtx = mtmd_init_from_file(mmprojPath, model, mparams)
            }
            if mtmdCtx == nil {
                throw LlamaError.mtmdInitFailed
            }
        }

        let result = LlamaContext(
            model: model,
            context: context,
            mtmd: mtmdCtx,
            contextLength: Int32(ctx_params.n_ctx),
            temperature: temperature,
            topK: topK,
            topP: topP,
            repeatPenalty: repeatPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            imageEvalBatchCap: imageEvalBatchSize
        )
        ownershipTransferred = true
        return result
    }

    private func ensurePromptBatchCapacity(promptTokens: Int32) {
        // Only needed for the initial prompt decode (we add many tokens at once).
        guard promptTokens > batchCapacity else { return }
        let n_ctx = Int32(llama_n_ctx(context))
        let newCap = min(promptTokens, n_ctx)
        llama_batch_free(batch)
        batchCapacity = newCap
        batch = llama_batch_init(batchCapacity, 0, 1)
    }

    func updateSampling(temperature: Float, topK: Int32, topP: Float, repeatPenalty: Float, presencePenalty: Float, frequencyPenalty: Float, seed: UInt32) {
        let next = Self.makeSampler(
            temperature: temperature,
            topK: topK,
            topP: topP,
            repeatPenalty: repeatPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed
        )
        llama_sampler_free(sampling)
        sampling = next
    }

    private static func makeSampler(
        temperature: Float,
        topK: Int32,
        topP: Float,
        repeatPenalty: Float,
        presencePenalty: Float,
        frequencyPenalty: Float,
        seed: UInt32
    ) -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            fatalError("Failed to init llama sampler chain")
        }

        if repeatPenalty != 1.0 || presencePenalty > 0 || frequencyPenalty > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                /* penalty_last_n */ 64,
                /* penalty_repeat */ repeatPenalty,
                /* penalty_freq   */ frequencyPenalty,
                /* penalty_present*/ presencePenalty
            ))
        }

        if topK > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        }
        if topP > 0 && topP < 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        }

        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        return chain
    }

    func requestStop() {
        guard isClosed == false else { return }
        shouldStop = true
    }

    func completion_init(text: String, imageURL: URL?, maxNewTokens: Int32) throws {
        guard isClosed == false else { throw CancellationError() }
        shouldStop = false
        is_done = false
        n_decode = 0

        maxNewTokensRemaining = max(0, maxNewTokens)

        // Important for M-RoPE models (e.g. Qwen): positions must be monotonic.
        // Since PocketLLM rebuilds the full prompt each send, clear KV cache here.
        llama_memory_clear(llama_get_memory(context), true)

        if let imageURL {
            try completion_init_mtmd(text: text, imageURL: imageURL)
            return
        }

        tokens_list = tokenize(text: text, add_bos: true)
        temporary_invalid_cchars = []

        // total token budget = prompt + maxNewTokens
        let promptTokens = Int32(tokens_list.count)

        let n_ctx = Int32(llama_n_ctx(context))
        if promptTokens >= n_ctx {
            is_done = true
            throw LlamaError.promptTooLong(promptTokens: promptTokens, contextLength: n_ctx)
        }

        n_len = min(n_ctx, promptTokens + max(1, maxNewTokens))

        // Ensure our batch arrays can fit the whole prompt.
        ensurePromptBatchCapacity(promptTokens: promptTokens)
        let n_kv_req = tokens_list.count + (Int(n_len) - tokens_list.count)
        if n_kv_req > Int(n_ctx) {
            print("warning: required KV cache may exceed n_ctx")
        }

        let maxBatchTokens = max(1, Int(llama_n_batch(context)))
        var offset = 0

        while offset < tokens_list.count {
            let end = min(offset + maxBatchTokens, tokens_list.count)

            batchClear()
            for i in offset..<end {
                let needsLogits = (i == tokens_list.count - 1)
                batchAdd(tokens_list[i], Int32(i), [0], needsLogits)
            }

            let ret = llama_decode(context, batch)
            if ret != 0 {
                is_done = true
                print("llama_decode() failed, ret = \(ret)")
                throw LlamaError.decodeFailed(ret)
            }

            offset = end
            n_cur = Int32(end)
        }
    }

    private func completion_init_mtmd(text: String, imageURL: URL) throws {
        guard isClosed == false else { throw CancellationError() }
        guard let mtmd else {
            throw LlamaError.visionNotAvailable
        }

        #if canImport(UIKit)
        let bitmap = mtmd_helper_bitmap_init_from_file(mtmd, imageURL.path)
        guard let bitmap else {
            throw LlamaError.imageLoadFailed
        }
        defer { mtmd_bitmap_free(bitmap) }

        guard let chunks = mtmd_input_chunks_init() else {
            throw LlamaError.mtmdInitFailed
        }
        defer { mtmd_input_chunks_free(chunks) }

        var inputText = mtmd_input_text(text: nil, add_special: true, parse_special: true)

        let resTok: Int32 = text.withCString { cstr in
            inputText.text = cstr
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { buf in
                let bmpPtr = buf.baseAddress!
                return mtmd_tokenize(mtmd, chunks, &inputText, bmpPtr, 1)
            }
        }
        if resTok != 0 {
            throw LlamaError.mtmdTokenizeFailed(resTok)
        }

        var newNPast: llama_pos = 0
        let imageEvalBatch = min(Int32(llama_n_batch(context)), imageEvalBatchCap)
        print("mtmd eval chunks: n_batch=\(llama_n_batch(context)), imageEvalBatch=\(imageEvalBatch), image=\(imageURL.lastPathComponent)")
        let resEval = mtmd_helper_eval_chunks(
            mtmd,
            context,
            chunks,
            0,
            0,
            imageEvalBatch,
            true,
            &newNPast
        )
        if resEval != 0 {
            throw LlamaError.mtmdEvalFailed(resEval)
        }

        // Continue generation positions from evaluated prompt positions.
        n_cur = Int32(newNPast)
        temporary_invalid_cchars = []

        let n_ctx = Int32(llama_n_ctx(context))
        let remainingContext = n_ctx - n_cur
        let reservedGenerationTokens = min(max(32, maxNewTokensRemaining / 4), 128)
        print("mtmd prompt evaluated: n_past=\(n_cur), n_ctx=\(n_ctx), remaining=\(remainingContext), reserved_generation=\(reservedGenerationTokens)")
        if remainingContext <= 1 || remainingContext < reservedGenerationTokens {
            is_done = true
            throw LlamaError.promptTooLong(promptTokens: n_cur, contextLength: n_ctx)
        }
        n_len = min(n_ctx, n_cur + max(1, maxNewTokensRemaining))
        #else
        throw LlamaError.visionNotAvailable
        #endif
    }

    func completion_loop() throws -> String {
        guard isClosed == false else { throw CancellationError() }
        if shouldStop {
            is_done = true
            return ""
        }

        if maxNewTokensRemaining == 0 {
            is_done = true
            return ""
        }

        let new_token_id = llama_sampler_sample(sampling, context, -1)
        llama_sampler_accept(sampling, new_token_id)

        if llama_vocab_is_eog(vocab, new_token_id) || n_cur == n_len {
            is_done = true
            let tail = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            return tail
        }

        let new_token_cchars = token_to_piece(token: new_token_id)
        temporary_invalid_cchars.append(contentsOf: new_token_cchars)

        let new_token_str: String
        if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else if (0 ..< temporary_invalid_cchars.count).contains(where: { $0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil }) {
            let string = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else {
            new_token_str = ""
        }

        batchClear()
        batchAdd(new_token_id, n_cur, [0], true)

        let ret = llama_decode(context, batch)
        if ret != 0 {
            is_done = true
            print("failed to evaluate llama, ret = \(ret)")
            throw LlamaError.decodeFailed(ret)
        }

        n_decode += 1
        n_cur += 1
        maxNewTokensRemaining -= 1

        return new_token_str
    }

    func clear() {
        guard isClosed == false else { return }
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        llama_memory_clear(llama_get_memory(context), true)
    }

    private func tokenize(text: String, add_bos: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)

        var swiftTokens: [llama_token] = []
        for i in 0..<tokenCount {
            swiftTokens.append(tokens[Int(i)])
        }
        tokens.deallocate()
        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer { result.deallocate() }

        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)
        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer { newResult.deallocate() }

            let nNewTokens = llama_token_to_piece(vocab, token, newResult, -nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
