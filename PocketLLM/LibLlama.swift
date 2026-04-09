import Foundation
import Foundation
import llama

#if canImport(UIKit)
import UIKit
#endif

enum LlamaError: Error {
    case couldNotInitializeContext
    case decodeFailed(Int32)
    case promptTooLong(promptTokens: Int32, contextLength: Int32)
    case visionNotAvailable
    case imageLoadFailed
    case mtmdInitFailed
    case mtmdTokenizeFailed(Int32)
    case mtmdEvalFailed(Int32)
}

extension LlamaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .couldNotInitializeContext:
            return "Failed to initialize llama context."
        case .decodeFailed(let code):
            return "llama_decode failed (code: \(code))."
        case .promptTooLong(let promptTokens, let contextLength):
            return "Prompt too long (\(promptTokens) tokens) for context length \(contextLength). Clear chat or increase context length."
        case .visionNotAvailable:
            return "Vision is not available. Select an mmproj model and try again."
        case .imageLoadFailed:
            return "Failed to load the selected image."
        case .mtmdInitFailed:
            return "Failed to initialize multimodal context (mmproj)."
        case .mtmdTokenizeFailed(let code):
            return "Failed to tokenize multimodal prompt (code: \(code))."
        case .mtmdEvalFailed(let code):
            return "Failed to evaluate multimodal prompt (code: \(code))."
        }
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

    private var shouldStop: Bool = false

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

    init(model: OpaquePointer, context: OpaquePointer, mtmd: OpaquePointer?, contextLength: Int32, temperature: Float, topK: Int32, topP: Float, presencePenalty: Float, frequencyPenalty: Float, seed: UInt32) {
        self.model = model
        self.context = context
        self.mtmd = mtmd
        self.tokens_list = []
        self.batchCapacity = max(512, contextLength)
        self.batch = llama_batch_init(self.batchCapacity, 0, 1)
        self.temporary_invalid_cchars = []
        self.vocab = llama_model_get_vocab(model)

        self.sampling = Self.makeSampler(
            temperature: temperature,
            topK: topK,
            topP: topP,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed
        )
    }

    deinit {
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        if let mtmd {
            mtmd_free(mtmd)
        }
        llama_model_free(model)
        llama_free(context)
        llama_backend_free()
    }

    static func create_context(path: String, contextLength: Int32, temperature: Float, topK: Int32, topP: Float, presencePenalty: Float, frequencyPenalty: Float, mmprojPath: String?, seed: UInt32) throws -> LlamaContext {
        llama_backend_init()
        var model_params = llama_model_default_params()

#if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
#endif
        let model = llama_model_load_from_file(path, model_params)
        guard let model else {
            print("Could not load model at \(path)")
            throw LlamaError.couldNotInitializeContext
        }

        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        print("Using \(n_threads) threads")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = UInt32(max(256, contextLength))
        // Multimodal image decode (mtmd) needs a larger u-batch than the default 512,
        // but using full context length can blow up Metal memory on iPhone.
        // Cap to a safer value and rely on smaller images to keep image token count manageable.
        let multimodalBatchCap = min(max(768, contextLength / 4), 1024)
        ctx_params.n_batch = UInt32(multimodalBatchCap)
        ctx_params.n_ubatch = UInt32(multimodalBatchCap)
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            print("Could not load context!")
            throw LlamaError.couldNotInitializeContext
        }

        var mtmdCtx: OpaquePointer?
        if let mmprojPath {
            var mparams = mtmd_context_params_default()
            mparams.use_gpu = true
            mparams.print_timings = false
            mparams.n_threads = Int32(n_threads)
            mtmdCtx = mtmd_init_from_file(mmprojPath, model, mparams)
            if mtmdCtx == nil {
                throw LlamaError.mtmdInitFailed
            }
        }

        return LlamaContext(
            model: model,
            context: context,
            mtmd: mtmdCtx,
            contextLength: Int32(ctx_params.n_ctx),
            temperature: temperature,
            topK: topK,
            topP: topP,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed
        )
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

    func updateSampling(temperature: Float, topK: Int32, topP: Float, presencePenalty: Float, frequencyPenalty: Float, seed: UInt32) {
        let next = Self.makeSampler(
            temperature: temperature,
            topK: topK,
            topP: topP,
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
        presencePenalty: Float,
        frequencyPenalty: Float,
        seed: UInt32
    ) -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            fatalError("Failed to init llama sampler chain")
        }

        // Penalties (OpenAI-like) - repeat penalty disabled (1.0)
        if presencePenalty > 0 || frequencyPenalty > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                /* penalty_last_n */ 64,
                /* penalty_repeat */ 1.0,
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
        shouldStop = true
    }

    func completion_init(text: String, imageURL: URL?, maxNewTokens: Int32) throws {
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

        batchClear()
        for i1 in 0..<tokens_list.count {
            let i = Int(i1)
            batchAdd(tokens_list[i], Int32(i), [0], false)
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        let ret = llama_decode(context, batch)
        if ret != 0 {
            is_done = true
            print("llama_decode() failed, ret = \(ret)")
            throw LlamaError.decodeFailed(ret)
        }

        n_cur = batch.n_tokens
    }

    private func completion_init_mtmd(text: String, imageURL: URL) throws {
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
        let resEval = mtmd_helper_eval_chunks(
            mtmd,
            context,
            chunks,
            0,
            0,
            Int32(llama_n_batch(context)),
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
        n_len = min(n_ctx, n_cur + max(1, maxNewTokensRemaining))
        #else
        throw LlamaError.visionNotAvailable
        #endif
    }

    func completion_loop() -> String {
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

        n_decode += 1
        n_cur += 1
        maxNewTokensRemaining -= 1

        if llama_decode(context, batch) != 0 {
            print("failed to evaluate llama")
        }

        return new_token_str
    }

    func clear() {
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
