import Foundation
import Combine

#if canImport(Darwin)
import Darwin
#endif

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
typealias PlatformImage = Any
#endif

private struct MemorySnapshot {
    let footprint: UInt64?
    let available: UInt64?
}

private enum MemoryProbe {
    private static let megabyte: UInt64 = 1024 * 1024
    private static let pollInterval: UInt64 = 250_000_000
    private static let minimumWait: TimeInterval = 3.0
    private static let maximumWait: TimeInterval = 12.0
    private static let meaningfulChange = 256 * megabyte
    private static let stableThreshold = 64 * megabyte

    static func snapshot() -> MemorySnapshot {
        MemorySnapshot(footprint: currentFootprint(), available: currentAvailableMemory())
    }

    static func waitForRelease(after initial: MemorySnapshot, reason: String) async {
        let start = CFAbsoluteTimeGetCurrent()
        var last = snapshot()
        var lowFootprint = last.footprint ?? initial.footprint
        var highAvailable = last.available ?? initial.available
        var stableSamples = 0

        while CFAbsoluteTimeGetCurrent() - start < maximumWait {
            try? await Task.sleep(nanoseconds: pollInterval)
            let current = snapshot()

            if let footprint = current.footprint {
                if lowFootprint == nil || footprint < lowFootprint! {
                    lowFootprint = footprint
                }
            }
            if let available = current.available {
                if highAvailable == nil || available > highAvailable! {
                    highAvailable = available
                }
            }

            if isStable(current, comparedTo: last) {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            last = current

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            guard elapsed >= minimumWait else { continue }

            let footprintReleased = released(from: initial.footprint, to: lowFootprint, direction: .decrease)
            let availableReleased = released(from: initial.available, to: highAvailable, direction: .increase)
            if footprintReleased || availableReleased || stableSamples >= 6 {
                print("Memory release wait (\(reason)) finished after \(String(format: "%.2f", elapsed))s, stableSamples=\(stableSamples), initial=\(describe(initial)), current=\(describe(current))")
                return
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("Memory release wait (\(reason)) timed out after \(String(format: "%.2f", elapsed))s, initial=\(describe(initial)), current=\(describe(last))")
    }

    private enum Direction {
        case decrease
        case increase
    }

    private static func released(from initial: UInt64?, to observed: UInt64?, direction: Direction) -> Bool {
        guard let initial, let observed else { return false }
        switch direction {
        case .decrease:
            return initial > observed && initial - observed >= meaningfulChange
        case .increase:
            return observed > initial && observed - initial >= meaningfulChange
        }
    }

    private static func isStable(_ current: MemorySnapshot, comparedTo previous: MemorySnapshot) -> Bool {
        let footprintStable = isStable(current.footprint, previous.footprint)
        let availableStable = isStable(current.available, previous.available)
        return footprintStable || availableStable
    }

    private static func isStable(_ current: UInt64?, _ previous: UInt64?) -> Bool {
        guard let current, let previous else { return false }
        return current > previous ? current - previous < stableThreshold : previous - current < stableThreshold
    }

    private static func describe(_ snapshot: MemorySnapshot) -> String {
        "footprint=\(format(snapshot.footprint)), available=\(format(snapshot.available))"
    }

    private static func format(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unknown" }
        return String(format: "%.0fMB", Double(bytes) / Double(megabyte))
    }

    private static func currentFootprint() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
    }

    private static func currentAvailableMemory() -> UInt64? {
        #if canImport(Darwin)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "os_proc_available_memory") else { return nil }
        typealias AvailableMemoryFunction = @convention(c) () -> UInt64
        let function = unsafeBitCast(symbol, to: AvailableMemoryFunction.self)
        return function()
        #else
        return nil
        #endif
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    static let defaultSystemPrompt = "You are a helpful assistant. Reply in the same language as the user. If the user writes Chinese, reply in Chinese. Reply in Markdown. Use explicit line breaks: put each bullet/list item on its own line. Do not output <think> blocks."
    static let defaultMessages: [ChatMessage] = [
        ChatMessage(role: .system, text: defaultSystemPrompt)
    ]

    @Published var messages: [ChatMessage]
    @Published var draft: String = ""
    @Published var isGenerating = false
    @Published var isSwitchingModel = false
    @Published var modelLoadingMessage: String = "模型加载中"
    @Published var errorMessage: String?
    @Published var streamingAssistantID: UUID?
    @Published var pendingImage: PlatformImage?

    private let modelStore: ModelStore
    private let settings: GenerationSettings
    private let sessionStore: SessionStore
    private let engine = LLMEngine()

    private var generationTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var selectionRequestID: Int = 0
    private var isChatActive = false
    private var cancellables = Set<AnyCancellable>()

    var activeModelName: String {
        modelStore.activeModel()?.name.quantizationDisplayName ?? "未选择模型"
    }

    var activeModelID: String? {
        modelStore.activeModelID
    }

    var installedModels: [ModelDescriptor] {
        modelStore.installed.filter { $0.kind == .model }
    }

    var activeModelIsMiniCPMV46: Bool {
        modelStore.activeModel()?.isMiniCPMV46 == true
    }

    var activeModelIsGemma4: Bool {
        modelStore.activeModel()?.isGemma4 == true
    }

    var activeModelIsVLM: Bool {
        modelStore.activeModel()?.metadata.category == .vlm
    }

    var activeModelHasSpecialSettings: Bool {
        activeModelIsMiniCPMV46
    }

    var maxNewTokens: Int32 {
        get { settings.maxNewTokens }
        set { settings.maxNewTokens = max(16, min(4096, newValue)) }
    }

    var contextLength: Int32 {
        get { settings.contextLength }
        set { settings.contextLength = max(512, min(16384, newValue)) }
    }

    var temperature: Float {
        get { settings.temperature }
        set { settings.temperature = max(0.0, min(1.5, newValue)) }
    }

    var topK: Int32 {
        get { settings.topK }
        set { settings.topK = max(0, min(200, newValue)) }
    }

    var topP: Float {
        get { settings.topP }
        set { settings.topP = max(0.0, min(1.0, newValue)) }
    }

    var presencePenalty: Float {
        get { settings.presencePenalty }
        set { settings.presencePenalty = max(0.0, min(2.0, newValue)) }
    }

    var frequencyPenalty: Float {
        get { settings.frequencyPenalty }
        set { settings.frequencyPenalty = max(0.0, min(2.0, newValue)) }
    }

    var seed: UInt32 {
        get { settings.seed }
        set { settings.seed = newValue }
    }

    var miniCPMV46ImageSlices: Int32 {
        get { settings.miniCPMV46ImageSlices }
        set { settings.miniCPMV46ImageSlices = max(1, min(9, newValue)) }
    }

    func randomizeSeed() {
        settings.seed = UInt32.random(in: 1...UInt32.max)
    }

    var gemmaMaxNewTokens: Int32 { settings.gemmaMaxNewTokens }
    var gemmaTemperature: Float { settings.gemmaTemperature }
    var gemmaTopK: Int32 { settings.gemmaTopK }
    var gemmaTopP: Float { settings.gemmaTopP }
    var gemmaUseGPU: Bool { settings.gemmaUseGPU }
    var gemmaThinkingEnabled: Bool { settings.gemmaThinkingEnabled }

    func applyGemmaSettings(maxNewTokens: Int32, temperature: Float, topK: Int32, topP: Float, useGPU: Bool, thinkingEnabled: Bool) {
        settings.gemmaMaxNewTokens = max(16, min(32000, maxNewTokens))
        settings.gemmaTemperature = max(0.0, min(2.0, temperature))
        settings.gemmaTopK = max(0, min(64, topK))
        settings.gemmaTopP = max(0.0, min(1.0, topP))
        settings.gemmaUseGPU = useGPU
        settings.gemmaThinkingEnabled = thinkingEnabled
        handleSelectionChange()
    }

    init(modelStore: ModelStore, settings: GenerationSettings, sessionStore: SessionStore) {
        self.modelStore = modelStore
        self.settings = settings
        self.sessionStore = sessionStore
        self.messages = sessionStore.messages

        $messages
            .dropFirst()
            .sink { [weak self] messages in
                self?.sessionStore.updateMessages(messages)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(modelStore.$activeModelID, modelStore.$activeMMProjID, settings.$contextLength)
            .dropFirst()
            .sink { [weak self] _, _, _ in
                self?.handleSelectionChange()
            }
            .store(in: &cancellables)

        settings.$miniCPMV46ImageSlices
            .dropFirst()
            .sink { [weak self] _ in
                self?.handleSelectionChange()
            }
            .store(in: &cancellables)

        modelStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func setPendingImage(_ image: PlatformImage) {
        guard activeModelIsVLM else {
            errorMessage = "当前文本模型不支持图片输入。请选择视觉模型后再上传图片。"
            pendingImage = nil
            return
        }
        pendingImage = image
    }

    func clearPendingImage() {
        pendingImage = nil
    }

    func selectModel(_ model: ModelDescriptor) {
        if model.id != modelStore.activeModelID {
            messages = Self.defaultMessages
            draft = ""
            errorMessage = nil
            streamingAssistantID = nil
            pendingImage = nil
            sessionStore.reset(messages: messages)
        }
        modelStore.setActiveModel(model)
    }

    func prepareForChat() {
        isChatActive = true
        guard modelStore.activeModelURL() != nil else { return }
        guard isSwitchingModel == false else { return }

        selectionRequestID += 1
        let requestID = selectionRequestID

        preloadTask?.cancel()
        isSwitchingModel = true
        modelLoadingMessage = "模型加载中"
        preloadTask = Task { @MainActor in
            do {
                try await self.loadActiveModelForCurrentSelection()
                guard self.selectionRequestID == requestID else { return }
                self.isSwitchingModel = false
            } catch is CancellationError {
                // chat disappeared or selection changed
            } catch {
                guard self.selectionRequestID == requestID else { return }
                self.errorMessage = error.localizedDescription
                self.isSwitchingModel = false
            }
        }
    }

    func leaveChat() {
        isChatActive = false
    }

    func send() {
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        if image != nil, activeModelIsVLM == false {
            pendingImage = nil
            errorMessage = "当前文本模型不支持图片输入。请选择视觉模型后再上传图片。"
            return
        }
        guard !text.isEmpty || image != nil else { return }
        draft = ""
        errorMessage = nil

        // Single-image mode: each new image starts a fresh visual context.
        // Keep only the system prompt to avoid carrying prior image-heavy history
        // into the next multimodal prompt, which quickly blows up token/memory usage.
        var attachments: [ChatAttachment] = []
        #if canImport(UIKit)
        if let image {
            do {
                let attachment = try persistImageAttachment(image)
                attachments = [attachment]
            } catch {
                errorMessage = "Failed to attach image: \(error.localizedDescription)"
            }
        }
        #endif

        let userMessageID = UUID()
        messages.append(ChatMessage(id: userMessageID, role: .user, text: text, attachments: attachments))
        pendingImage = nil
        let promptSnapshot = messages // exclude the streaming placeholder

        let assistantID = UUID()
        streamingAssistantID = assistantID
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))

        guard let modelURL = modelStore.activeModelURL() else {
            errorMessage = "Select or download a model first."
            isGenerating = false
            return
        }

        let imageURL = attachments.first(where: { $0.type == .image })?.url
        let mmprojURL = imageURL != nil ? modelStore.compatibleActiveMMProjURL() : nil
        if imageURL != nil, mmprojURL == nil {
            errorMessage = modelStore.activeMMProjCompatibilityError() ?? "Download and select a matching mmproj model first."
            isGenerating = false
            return
        }

        isGenerating = true

        generationTask = Task { @MainActor in
            do {
                let pendingPreloadTask = preloadTask
                await pendingPreloadTask?.value
                try Task.checkCancellation()

                let activeModel = modelStore.activeModel()
                let isMiniCPMV46 = activeModel?.isMiniCPMV46 == true
                let isGemma4 = activeModel?.isGemma4 == true
                let effectiveTemperature = isGemma4 ? settings.gemmaTemperature : settings.temperature
                let effectiveTopK = isMiniCPMV46 ? Int32(0) : settings.topK
                let effectiveTopP = isMiniCPMV46 ? Float(1.0) : settings.topP
                let effectivePresencePenalty = isMiniCPMV46 ? Float(0.0) : settings.presencePenalty
                let effectiveFrequencyPenalty = isMiniCPMV46 ? Float(0.0) : settings.frequencyPenalty
                let effectiveUseGPU = isGemma4 ? settings.gemmaUseGPU : true

                try await engine.loadIfNeeded(
                    modelURL: modelURL,
                    contextLength: settings.contextLength,
                    temperature: effectiveTemperature,
                    topK: isGemma4 ? settings.gemmaTopK : effectiveTopK,
                    topP: isGemma4 ? settings.gemmaTopP : effectiveTopP,
                    presencePenalty: effectivePresencePenalty,
                    frequencyPenalty: effectiveFrequencyPenalty,
                    mmprojURL: mmprojURL,
                    seed: settings.seed,
                    imageMaxSlices: isMiniCPMV46 ? settings.miniCPMV46ImageSlices : 9,
                    useGPU: effectiveUseGPU
                )

        let prompt = PromptBuilder.buildPrompt(
            from: promptSnapshot,
            style: activeModel?.promptStyle ?? .chatML,
            activeImageMessageID: imageURL != nil ? userMessageID : nil,
            maxRecentRounds: 2,
            gemmaThinkingEnabled: isGemma4 && settings.gemmaThinkingEnabled
        )
                let maxNewTokens = isGemma4 ? settings.gemmaMaxNewTokens : settings.maxNewTokens
                let metrics = try await engine.generate(prompt: prompt, imageURL: imageURL, maxNewTokens: maxNewTokens, requestStartedAt: requestStartedAt) { token in
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        // Streaming: do NOT trim trailing newlines, otherwise list formatting breaks
                        // whenever a newline arrives as a standalone token.
                        let updated = self.messages[idx].text + token
                        self.messages[idx].text = PromptBuilder.postprocessAssistantTextStreaming(updated)
                    }
                }

                // Final cleanup after generation completes.
                if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.messages[idx].text = PromptBuilder.postprocessAssistantTextFinal(self.messages[idx].text)
                    self.messages[idx].stats = GenerationStats(
                        ttftSeconds: metrics.ttftSeconds,
                        tokensPerSecond: metrics.tokensPerSecond,
                        totalSeconds: metrics.totalSeconds,
                        generatedTokenCount: metrics.generatedTokenCount
                    )
                }
            } catch is CancellationError {
                // user stopped generation
            } catch {
                self.errorMessage = error.localizedDescription
            }

            self.isGenerating = false
            self.streamingAssistantID = nil
        }
    }

    func stop() {
        generationTask?.cancel()
        Task { await engine.stop() }
        isGenerating = false
        streamingAssistantID = nil
    }

    private func handleSelectionChange(loadingMessage: String? = nil) {
        selectionRequestID += 1
        let requestID = selectionRequestID

        guard modelStore.activeModelURL() != nil else {
            isSwitchingModel = false
            modelLoadingMessage = "模型加载中"
            let previousGenerationTask = generationTask
            let previousPreloadTask = preloadTask
            generationTask?.cancel()
            isGenerating = false
            streamingAssistantID = nil

            preloadTask?.cancel()
            preloadTask = Task { @MainActor in
                await engine.stop()
                await previousGenerationTask?.value
                await previousPreloadTask?.value
                await engine.unload()
                guard self.selectionRequestID == requestID else { return }
                self.isSwitchingModel = false
            }
            return
        }

        guard isChatActive else {
            isSwitchingModel = false
            modelLoadingMessage = "模型加载中"
            return
        }

        isSwitchingModel = true
        if let loadingMessage {
            modelLoadingMessage = loadingMessage
        } else {
            modelLoadingMessage = "模型加载中"
        }

        let previousGenerationTask = generationTask
        let previousPreloadTask = preloadTask
        generationTask?.cancel()
        isGenerating = false
        streamingAssistantID = nil

        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            await engine.stop()
            await previousGenerationTask?.value
            await previousPreloadTask?.value
            let memoryBeforeUnload = MemoryProbe.snapshot()
            await engine.unload()
            guard self.selectionRequestID == requestID else { return }
            await MemoryProbe.waitForRelease(after: memoryBeforeUnload, reason: "model switch")
            guard self.selectionRequestID == requestID else { return }

            self.modelLoadingMessage = "模型加载中"
            do {
                try await self.loadActiveModelForCurrentSelection()
                guard self.selectionRequestID == requestID else { return }
                self.isSwitchingModel = false
            } catch is CancellationError {
                // selection changed again
            } catch {
                guard self.selectionRequestID == requestID else { return }
                self.errorMessage = error.localizedDescription
                self.isSwitchingModel = false
            }
        }
    }

    func clearChat() {
        stop()
        messages = Self.defaultMessages
        errorMessage = nil
        streamingAssistantID = nil
        pendingImage = nil
        sessionStore.reset(messages: messages)
        handleSelectionChange(loadingMessage: "清空对话和模型加载中")
    }

    func startDemo(prompt: String) {
        stop()
        messages = Self.defaultMessages
        errorMessage = nil
        streamingAssistantID = nil
        pendingImage = nil
        draft = prompt
        sessionStore.reset(messages: messages)
    }

    private func persistImageAttachment(_ image: UIImage) throws -> ChatAttachment {
        let uuid = UUID().uuidString
        let filename = "\(uuid).jpg"
        let url = FileLocations.attachmentFileURL(filename: filename)

        // Multimodal image tokens grow quickly with resolution.
        // Keep images smaller on iPhone to avoid huge mtmd/KV allocations.
        // Keep multimodal images small enough so visual tokens fit in a single batch on-device.
        // This is a stability tradeoff for iPhone memory / mtmd batching.
        let maxImageDimension: CGFloat = modelStore.activeModel()?.isMiniCPMV46 == true ? 512 : 768
        let scaled = image.scaledDown(maxDimension: maxImageDimension)
        guard let data = scaled.jpegData(compressionQuality: 0.9) else {
            throw NSError(domain: "PocketLLM", code: 2, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }

        try data.write(to: url, options: .atomic)
        try url.excludeFromBackup()

        return ChatAttachment(type: .image, localPath: url.path)
    }

    private func loadActiveModelForCurrentSelection() async throws {
        guard let modelURL = modelStore.activeModelURL() else { return }

        let mmprojURL = modelStore.compatibleActiveMMProjURL()
        let activeModel = modelStore.activeModel()
        let isMiniCPMV46 = activeModel?.isMiniCPMV46 == true
        let isGemma4 = activeModel?.isGemma4 == true
        let temperature = isGemma4 ? settings.gemmaTemperature : settings.temperature
        let topK = isGemma4 ? settings.gemmaTopK : (isMiniCPMV46 ? Int32(0) : settings.topK)
        let topP = isGemma4 ? settings.gemmaTopP : (isMiniCPMV46 ? Float(1.0) : settings.topP)
        let presencePenalty = isMiniCPMV46 ? Float(0.0) : settings.presencePenalty
        let frequencyPenalty = isMiniCPMV46 ? Float(0.0) : settings.frequencyPenalty
        let imageMaxSlices = isMiniCPMV46 ? settings.miniCPMV46ImageSlices : 9
        let useGPU = isGemma4 ? settings.gemmaUseGPU : true

        try await engine.loadIfNeeded(
            modelURL: modelURL,
            contextLength: settings.contextLength,
            temperature: temperature,
            topK: topK,
            topP: topP,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            mmprojURL: mmprojURL,
            seed: settings.seed,
            imageMaxSlices: imageMaxSlices,
            useGPU: useGPU
        )
    }

}

private extension UIImage {
    func scaledDown(maxDimension: CGFloat) -> UIImage {
        let size = self.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else { return self }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

actor LLMEngine {
    struct GenerationMetrics {
        let ttftSeconds: Double
        let tokensPerSecond: Double
        let totalSeconds: Double
        let generatedTokenCount: Int
    }

    private var ctx: LlamaContext?
    private var loadedModelPath: String?
    private var loadedContextLength: Int32?
    private var loadedTemperature: Float?
    private var loadedTopK: Int32?
    private var loadedTopP: Float?
    private var loadedPresencePenalty: Float?
    private var loadedFrequencyPenalty: Float?
    private var loadedMMProjPath: String?
    private var loadedSeed: UInt32?
    private var loadedImageMaxSlices: Int32?
    private var loadedUseGPU: Bool?
    private var lifecycleOperationID = UUID()
    private var contextCloseTask: Task<Void, Never>?
    private var contextCloseTaskID: UUID?

    func loadIfNeeded(
        modelURL: URL,
        contextLength: Int32,
        temperature: Float,
        topK: Int32,
        topP: Float,
        presencePenalty: Float,
        frequencyPenalty: Float,
        mmprojURL: URL?,
        seed: UInt32,
        imageMaxSlices: Int32,
        useGPU: Bool
    ) async throws {
        let path = modelURL.path
        let mmprojPath = mmprojURL?.path
        await waitForContextCloseIfNeeded()

        let needsReload = (ctx == nil)
            || (loadedModelPath != path)
            || (loadedContextLength != contextLength)
            || (loadedMMProjPath != mmprojPath)
            || (loadedImageMaxSlices != imageMaxSlices)
            || (loadedUseGPU != useGPU)

        if needsReload {
            let operationID = UUID()
            lifecycleOperationID = operationID
            let memoryBeforeUnload = MemoryProbe.snapshot()
            let didUnloadContext = await unloadCurrentContext()
            try Task.checkCancellation()
            guard lifecycleOperationID == operationID else { throw CancellationError() }
            if didUnloadContext {
                await MemoryProbe.waitForRelease(after: memoryBeforeUnload, reason: "engine reload")
                try Task.checkCancellation()
                guard lifecycleOperationID == operationID else { throw CancellationError() }
            }

            let nextContext = try autoreleasepool {
                try LlamaContext.create_context(
                    path: path,
                    contextLength: contextLength,
                    temperature: temperature,
                    topK: topK,
                    topP: topP,
                    presencePenalty: presencePenalty,
                    frequencyPenalty: frequencyPenalty,
                    mmprojPath: mmprojPath,
                    seed: seed,
                    imageMaxSlices: imageMaxSlices,
                    useGPU: useGPU
                )
            }
            try Task.checkCancellation()
            guard lifecycleOperationID == operationID else { throw CancellationError() }

            ctx = nextContext

            loadedModelPath = path
            loadedContextLength = contextLength
            loadedTemperature = temperature
            loadedTopK = topK
            loadedTopP = topP
            loadedPresencePenalty = presencePenalty
            loadedFrequencyPenalty = frequencyPenalty
            loadedMMProjPath = mmprojPath
            loadedSeed = seed
            loadedImageMaxSlices = imageMaxSlices
            loadedUseGPU = useGPU
            return
        }

        // Same model/context: allow updating sampling without reloading.
        if loadedTemperature != temperature
            || loadedTopK != topK
            || loadedTopP != topP
            || loadedPresencePenalty != presencePenalty
            || loadedFrequencyPenalty != frequencyPenalty
            || loadedSeed != seed {
            await ctx?.updateSampling(
                temperature: temperature,
                topK: topK,
                topP: topP,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed
            )
            loadedTemperature = temperature
            loadedTopK = topK
            loadedTopP = topP
            loadedPresencePenalty = presencePenalty
            loadedFrequencyPenalty = frequencyPenalty
            loadedSeed = seed
        }
    }

    func generate(prompt: String, imageURL: URL?, maxNewTokens: Int32, requestStartedAt: CFAbsoluteTime, onToken: @MainActor @Sendable (String) async -> Void) async throws -> GenerationMetrics {
        guard let ctx else { throw NSError(domain: "PocketLLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }
        var firstTokenAt: Double?
        var generatedTokenCount = 0
        do {
            try await ctx.completion_init(text: prompt, imageURL: imageURL, maxNewTokens: maxNewTokens)

            // Stop sequences for ChatML-style templates.
            // Prevent the model from continuing into the next <|im_start|>user/... turn.
            let stopSequences = [
                "<|im_end|>",
                "<|im_start|>user",
                "<|im_start|>system",
            ]
            let maxStopLen = stopSequences.map { $0.count }.max() ?? 0
            var pending = ""

            while await !ctx.is_done {
                try Task.checkCancellation()
                let token = try await ctx.completion_loop()
                generatedTokenCount += 1
                if firstTokenAt == nil {
                    firstTokenAt = CFAbsoluteTimeGetCurrent()
                }
                if !token.isEmpty {
                    pending += token

                    if let (emit, shouldStop) = Self.consumeStopsIfPresent(&pending, stopSequences: stopSequences) {
                        if !emit.isEmpty {
                            await onToken(emit)
                        }
                        if shouldStop {
                            break
                        }
                    }

                    // Flush safe prefix while keeping a tail for stop-boundary matching.
                    if maxStopLen > 0, pending.count > maxStopLen {
                        let cutIndex = pending.index(pending.endIndex, offsetBy: -maxStopLen)
                        let safePrefix = String(pending[..<cutIndex])
                        pending = String(pending[cutIndex...])
                        if !safePrefix.isEmpty {
                            await onToken(safePrefix)
                        }
                    }
                }
            }

            // Flush remaining content exactly once, trimming any stop artifacts.
            if !pending.isEmpty {
                let cleaned = Self.trimStopArtifacts(pending)
                if !cleaned.isEmpty {
                    await onToken(cleaned)
                }
                pending = ""
            }
            await ctx.clear()
            let finishedAt = CFAbsoluteTimeGetCurrent()
            let ttft = max(0, (firstTokenAt ?? finishedAt) - requestStartedAt)
            let generationWindow = max(0.001, finishedAt - (firstTokenAt ?? finishedAt))
            let tps = Double(generatedTokenCount) / generationWindow
            return GenerationMetrics(
                ttftSeconds: ttft,
                tokensPerSecond: tps,
                totalSeconds: max(0, finishedAt - requestStartedAt),
                generatedTokenCount: generatedTokenCount
            )
        } catch {
            await ctx.clear()
            throw error
        }
    }

    private static func consumeStopsIfPresent(_ pending: inout String, stopSequences: [String]) -> (String, Bool)? {
        var earliest: Range<String.Index>?
        for seq in stopSequences {
            if let r = pending.range(of: seq) {
                if earliest == nil || r.lowerBound < earliest!.lowerBound {
                    earliest = r
                }
            }
        }

        guard let earliest else { return nil }
        let emit = String(pending[..<earliest.lowerBound])
        pending = ""
        return (emit, true)
    }

    private static func trimStopArtifacts(_ text: String) -> String {
        var out = text
        for artifact in ["<|im_end|>", "<|im_start|>assistant", "<|im_start|>", "|im_start|>assistant", "im_start|>assistant", "m_start|>assistant"] {
            if let r = out.range(of: artifact) {
                out.removeSubrange(r.lowerBound..<out.endIndex)
            }
        }

        let trailingArtifacts = ["assistant", "ssistant", "istant"]
        for artifact in trailingArtifacts {
            if out.hasSuffix(artifact) {
                out.removeLast(artifact.count)
                break
            }
        }
        return out
    }

    func stop() async {
        await ctx?.requestStop()
    }

    func unload() async {
        lifecycleOperationID = UUID()
        await unloadCurrentContext()
    }

    @discardableResult
    private func unloadCurrentContext() async -> Bool {
        await waitForContextCloseIfNeeded()

        let currentContext = ctx
        ctx = nil
        loadedModelPath = nil
        loadedContextLength = nil
        loadedTemperature = nil
        loadedTopK = nil
        loadedTopP = nil
        loadedPresencePenalty = nil
        loadedFrequencyPenalty = nil
        loadedMMProjPath = nil
        loadedSeed = nil
        loadedImageMaxSlices = nil
        loadedUseGPU = nil

        if let currentContext {
            let closeID = UUID()
            let closeTask = Task {
                await currentContext.requestStop()
                await currentContext.close()
            }
            contextCloseTask = closeTask
            contextCloseTaskID = closeID
            await closeTask.value
            if contextCloseTaskID == closeID {
                contextCloseTask = nil
                contextCloseTaskID = nil
            }
            return true
        }
        return false
    }

    private func waitForContextCloseIfNeeded() async {
        guard let closeTask = contextCloseTask, let closeID = contextCloseTaskID else { return }
        await closeTask.value
        if contextCloseTaskID == closeID {
            contextCloseTask = nil
            contextCloseTaskID = nil
        }
    }
}

enum PromptBuilder {
    enum Style {
        case chatML
        case miniCPMV4
    }

    static func buildPrompt(from messages: [ChatMessage], style: Style = .chatML, activeImageMessageID: UUID? = nil, maxRecentRounds: Int = 3, gemmaThinkingEnabled: Bool = false) -> String {
        let system = messages.first(where: { $0.role == .system })?.text ?? ChatViewModel.defaultSystemPrompt
        let rounds = ConversationContextBuilder.rounds(from: messages)
        let currentUserText = rounds.last?.user.text ?? ""
        let isImageTurn = activeImageMessageID != nil

        let recentRounds: [ConversationContextBuilder.Round]
        let relatedSummary: String
        if isImageTurn {
            recentRounds = rounds.last.map { [$0] } ?? []
            relatedSummary = ""
        } else {
            recentRounds = Array(rounds.suffix(maxRecentRounds))
            relatedSummary = ConversationContextBuilder.relatedHistorySummary(
                allRounds: rounds,
                currentQuery: currentUserText,
                recentRoundsCount: recentRounds.count,
                maxItems: 3
            )
        }

        var enrichedSystem = system
        if gemmaThinkingEnabled {
            enrichedSystem = "<|think|>\n" + enrichedSystem
        }
        if !relatedSummary.isEmpty {
            enrichedSystem += "\n\nRelevant context from earlier in this session:\n\(relatedSummary)"
        }

        var out = ""
        if style == .chatML {
            out += "<|im_start|>system\n\(enrichedSystem)\n<|im_end|>\n"
        }

        for round in recentRounds {
            let m = round.user
            switch m.role {
            case .user:
                let hasImage = m.attachments.contains(where: { $0.type == .image })
                let userText: String
                if hasImage, m.id == activeImageMessageID {
                    let marker = "<__media__>"
                    userText = m.text.isEmpty ? marker : marker + "\n" + m.text
                } else if hasImage {
                    let placeholder = "[Image attached previously]"
                    userText = m.text.isEmpty ? placeholder : placeholder + "\n" + m.text
                } else {
                    userText = m.text
                }
                out += "<|im_start|>user\n\(userText)\n<|im_end|>\n"
                if let assistant = round.assistant {
                    out += "<|im_start|>assistant\n\(assistant.text)\n<|im_end|>\n"
                }
            default:
                break
            }
        }

        switch style {
        case .chatML:
            // Qwen3.5 ChatML template supports "thinking" (<think>...</think>).
            // To avoid emitting think tokens in the visible transcript, we prompt with an empty think block.
            out += "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .miniCPMV4:
            out += "<|im_start|>assistant\n"
        }
        return out
    }
}

private extension ModelDescriptor {
    var promptStyle: PromptBuilder.Style {
        isMiniCPMV4 ? .miniCPMV4 : .chatML
    }
}

private enum ConversationContextBuilder {
    struct Round {
        let user: ChatMessage
        let assistant: ChatMessage?
    }

    struct ScoredRound {
        let round: Round
        let score: Int
    }

    static func rounds(from messages: [ChatMessage]) -> [Round] {
        let convo = messages.filter { $0.role != .system }
        var rounds: [Round] = []
        var currentUser: ChatMessage?
        var currentAssistant: ChatMessage?

        for message in convo {
            switch message.role {
            case .user:
                if let currentUser {
                    rounds.append(Round(user: currentUser, assistant: currentAssistant))
                }
                currentUser = message
                currentAssistant = nil
            case .assistant:
                currentAssistant = message
            case .system:
                break
            }
        }

        if let currentUser {
            rounds.append(Round(user: currentUser, assistant: currentAssistant))
        }

        return rounds
    }

    static func relatedHistorySummary(allRounds: [Round], currentQuery: String, recentRoundsCount: Int, maxItems: Int) -> String {
        let olderRounds = Array(allRounds.dropLast(recentRoundsCount))
        guard !olderRounds.isEmpty else { return "" }

        let queryTerms = importantTerms(from: currentQuery)
        var scored: [ScoredRound] = []
        for round in olderRounds {
            let value = score(round: round, queryTerms: queryTerms)
            if value > 0 {
                scored.append(ScoredRound(round: round, score: value))
            }
        }

        let ranked = scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.round.user.createdAt > rhs.round.user.createdAt
                }
                return lhs.score > rhs.score
            }
            .prefix(maxItems)

        let lines = ranked.map { item -> String in
            let user = compact(item.round.user.text)
            let assistant = compact(item.round.assistant?.text ?? "")
            if assistant.isEmpty {
                return "- Earlier user ask: \(user)"
            }
            return "- Earlier related turn: User asked \"\(user)\"; assistant answered \"\(assistant)\""
        }

        return lines.joined(separator: "\n")
    }

    private static func importantTerms(from text: String) -> Set<String> {
        let stopwords: Set<String> = ["the","a","an","and","or","to","of","in","on","for","with","is","are","was","were","be","this","that","it","i","you","he","she","they","we","我","你","他","她","它","我们","你们","他们","的","了","和","是","在","就","都","而","及","与","着","或","一个","可以","请","帮我","一下"]
        let lowered = text.lowercased()
        let tokens = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(tokens.map(String.init).filter { $0.count >= 2 && !stopwords.contains($0) })
    }

    private static func compact(_ text: String, maxLength: Int = 120) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= maxLength { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: maxLength)
        return String(singleLine[..<end]) + "…"
    }

    private static func score(round: Round, queryTerms: Set<String>) -> Int {
        let userText = round.user.text
        let assistantText = round.assistant?.text ?? ""
        let haystack = userText + " " + assistantText
        let terms = importantTerms(from: haystack)
        let overlap = queryTerms.intersection(terms).count
        let imageBonus = round.user.attachments.isEmpty ? 0 : 1
        return (overlap * 5) + imageBonus
    }
}

extension PromptBuilder {
    static func postprocessAssistantTextStreaming(_ text: String) -> String {
        var s = text

        // Remove common template artifacts if they appear.
        for stop in ["<|im_end|>", "<|im_start|>"] {
            if let r = s.range(of: stop) {
                s.removeSubrange(r.lowerBound..<s.endIndex)
            }
        }

        s = stripGemmaThoughtChannel(s)

        // Hide <think> blocks from the visible transcript.
        s = stripThinkBlocks(s)

        // Some models emit "\\" as a line-break marker. Convert it to newlines.
        // IMPORTANT: do not trim trailing newlines while streaming.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let slashOnlyCount = lines.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "\\" }.count
        let totalLines = max(1, lines.count)
        if slashOnlyCount >= 2 || Double(slashOnlyCount) / Double(totalLines) > 0.2 {
            s = s.replacingOccurrences(of: "\r\n", with: "\n")
            s = s.replacingOccurrences(of: "\r", with: "\n")
            s = s.replacingOccurrences(of: "\n\\\n", with: "\n\n")
            s = s.replacingOccurrences(of: "\\\n", with: "\n")

            // Remove remaining solitary backslash lines.
            s = s
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "\\" ? "" : String($0) }
                .joined(separator: "\n")
        }

        return s
    }

    static func postprocessAssistantTextFinal(_ text: String) -> String {
        postprocessAssistantTextStreaming(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripThinkBlocks(_ input: String) -> String {
        var s = input

        // Handle stray closing tags (some generations may output </think> without a matching <think>).
        s = s.replacingOccurrences(of: "</think>", with: "")

        while let startRange = s.range(of: "<think>") {
            if let endRange = s.range(of: "</think>", range: startRange.upperBound..<s.endIndex) {
                // Remove from <think>..</think>
                s.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                // Incomplete think while streaming: hide from <think> to end
                s.removeSubrange(startRange.lowerBound..<s.endIndex)
                break
            }
        }

        // If anything still left (e.g. "<think>" literal), remove it.
        s = s.replacingOccurrences(of: "<think>", with: "")
        return s
    }

    private static func stripGemmaThoughtChannel(_ input: String) -> String {
        var s = input
        let startTokens = ["<|channel|>thought", "<|channel>thought"]
        let endTokens = ["<|channel|>final", "<|channel>final", "<channel|>"]

        while let start = startTokens.compactMap({ s.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let searchRange = start.upperBound..<s.endIndex
            if let end = endTokens.compactMap({ s.range(of: $0, range: searchRange) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
                break
            }
        }

        return s
    }
}
