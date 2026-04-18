import Foundation
import Combine

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
typealias PlatformImage = Any
#endif

@MainActor
final class ChatViewModel: ObservableObject {
    static let defaultSystemPrompt = "You are a helpful assistant. Reply in Markdown. Use explicit line breaks: put each bullet/list item on its own line. Do not output <think> blocks."
    static let defaultMessages: [ChatMessage] = [
        ChatMessage(role: .system, text: defaultSystemPrompt)
    ]

    @Published var messages: [ChatMessage]
    @Published var draft: String = ""
    @Published var isGenerating = false
    @Published var isSwitchingModel = false
    @Published var modelLoadingMessage: String = "Loading model..."
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
    private var cancellables = Set<AnyCancellable>()

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

        handleSelectionChange()
    }

    func setPendingImage(_ image: PlatformImage) {
        pendingImage = image
    }

    func clearPendingImage() {
        pendingImage = nil
    }

    func send() {
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
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
                try await engine.loadIfNeeded(
                    modelURL: modelURL,
                    contextLength: settings.contextLength,
                    temperature: settings.temperature,
                    topK: settings.topK,
                    topP: settings.topP,
                    presencePenalty: settings.presencePenalty,
                    frequencyPenalty: settings.frequencyPenalty,
                    mmprojURL: mmprojURL,
                    seed: settings.seed
                )

        let prompt = PromptBuilder.buildPrompt(
            from: promptSnapshot,
            activeImageMessageID: imageURL != nil ? userMessageID : nil,
            maxRecentRounds: 2
        )
                let metrics = try await engine.generate(prompt: prompt, imageURL: imageURL, maxNewTokens: settings.maxNewTokens, requestStartedAt: requestStartedAt) { token in
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
        generationTask = nil
        Task { await engine.stop() }
        isGenerating = false
        streamingAssistantID = nil
    }

    private func handleSelectionChange() {
        selectionRequestID += 1
        let requestID = selectionRequestID

        guard modelStore.activeModelURL() != nil else {
            isSwitchingModel = false
            modelLoadingMessage = "Loading model..."
            let previousGenerationTask = generationTask
            let previousPreloadTask = preloadTask
            generationTask?.cancel()
            generationTask = nil
            isGenerating = false
            streamingAssistantID = nil

            preloadTask?.cancel()
            preloadTask = Task { @MainActor in
                await engine.stop()
                await previousGenerationTask?.value
                await previousPreloadTask?.value
                await engine.unload()
            }
            return
        }

        isSwitchingModel = true
        if let model = modelStore.activeModel() {
            modelLoadingMessage = "Loading \(model.name)..."
        } else {
            modelLoadingMessage = "Loading model..."
        }

        let previousGenerationTask = generationTask
        let previousPreloadTask = preloadTask
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        streamingAssistantID = nil

        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            await engine.stop()
            await previousGenerationTask?.value
            await previousPreloadTask?.value
            await engine.unload()
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard self.selectionRequestID == requestID else { return }
            self.schedulePreloadForCurrentSelection(requestID: requestID)
        }
    }

    func clearChat() {
        stop()
        messages = Self.defaultMessages
        errorMessage = nil
        streamingAssistantID = nil
        pendingImage = nil
        sessionStore.reset(messages: messages)
        Task { await engine.unload() }
    }

    private func persistImageAttachment(_ image: UIImage) throws -> ChatAttachment {
        let uuid = UUID().uuidString
        let filename = "\(uuid).jpg"
        let url = FileLocations.attachmentFileURL(filename: filename)

        // Multimodal image tokens grow quickly with resolution.
        // Keep images smaller on iPhone to avoid huge mtmd/KV allocations.
        // Keep multimodal images small enough so visual tokens fit in a single batch on-device.
        // This is a stability tradeoff for iPhone memory / mtmd batching.
        let scaled = image.scaledDown(maxDimension: 384)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "PocketLLM", code: 2, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }

        try data.write(to: url, options: .atomic)
        try url.excludeFromBackup()

        return ChatAttachment(type: .image, localPath: url.path)
    }

    private func schedulePreloadForCurrentSelection(requestID: Int) {
        guard let modelURL = modelStore.activeModelURL() else {
            preloadTask = Task { await engine.unload() }
            return
        }

        let mmprojURL = modelStore.compatibleActiveMMProjURL()
        let contextLength = settings.contextLength
        let temperature = settings.temperature
        let topK = settings.topK
        let topP = settings.topP
        let presencePenalty = settings.presencePenalty
        let frequencyPenalty = settings.frequencyPenalty
        let seed = settings.seed

        preloadTask = Task {
            do {
                try await engine.loadIfNeeded(
                    modelURL: modelURL,
                    contextLength: contextLength,
                    temperature: temperature,
                    topK: topK,
                    topP: topP,
                    presencePenalty: presencePenalty,
                    frequencyPenalty: frequencyPenalty,
                    mmprojURL: mmprojURL,
                    seed: seed
                )
                await MainActor.run {
                    guard self.selectionRequestID == requestID else { return }
                    self.isSwitchingModel = false
                    self.modelLoadingMessage = "Loading model..."
                }
            } catch is CancellationError {
                // selection changed again
            } catch {
                await MainActor.run {
                    guard self.selectionRequestID == requestID else { return }
                    self.errorMessage = error.localizedDescription
                    self.isSwitchingModel = false
                    self.modelLoadingMessage = "Loading model..."
                }
            }
        }
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

    func loadIfNeeded(
        modelURL: URL,
        contextLength: Int32,
        temperature: Float,
        topK: Int32,
        topP: Float,
        presencePenalty: Float,
        frequencyPenalty: Float,
        mmprojURL: URL?,
        seed: UInt32
    ) async throws {
        let path = modelURL.path
        let mmprojPath = mmprojURL?.path

        let needsReload = (ctx == nil)
            || (loadedModelPath != path)
            || (loadedContextLength != contextLength)
            || (loadedMMProjPath != mmprojPath)

        if needsReload {
            await unload()

            ctx = try LlamaContext.create_context(
                path: path,
                contextLength: contextLength,
                temperature: temperature,
                topK: topK,
                topP: topP,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                mmprojPath: mmprojPath,
                seed: seed
            )

            loadedModelPath = path
            loadedContextLength = contextLength
            loadedTemperature = temperature
            loadedTopK = topK
            loadedTopP = topP
            loadedPresencePenalty = presencePenalty
            loadedFrequencyPenalty = frequencyPenalty
            loadedMMProjPath = mmprojPath
            loadedSeed = seed
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
        if let ctx {
            await ctx.requestStop()
            await ctx.clear()
        }
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
    }
}

enum PromptBuilder {
    static func buildPrompt(from messages: [ChatMessage], activeImageMessageID: UUID? = nil, maxRecentRounds: Int = 3) -> String {
        let system = messages.first(where: { $0.role == .system })?.text ?? ChatViewModel.defaultSystemPrompt
        let rounds = ConversationContextBuilder.rounds(from: messages)
        let currentUserText = rounds.last?.user.text ?? ""

        let recentRounds = Array(rounds.suffix(maxRecentRounds))
        let relatedSummary = ConversationContextBuilder.relatedHistorySummary(
            allRounds: rounds,
            currentQuery: currentUserText,
            recentRoundsCount: recentRounds.count,
            maxItems: 3
        )

        var enrichedSystem = system
        if !relatedSummary.isEmpty {
            enrichedSystem += "\n\nRelevant context from earlier in this session:\n\(relatedSummary)"
        }

        var out = "<|im_start|>system\n\(enrichedSystem)\n<|im_end|>\n"
        for round in recentRounds {
            let m = round.user
            switch m.role {
            case .user:
                let hasImage = m.attachments.contains(where: { $0.type == .image })
                let userText: String
                if hasImage, m.id == activeImageMessageID {
                    // Single-image mode: only the current image-bearing user message gets a media marker.
                    let marker = "<__media__>"
                    userText = m.text.isEmpty ? marker : marker + "\n" + m.text
                } else if hasImage {
                    // Preserve chat continuity without injecting stale media markers from history.
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
        // Qwen3.5 ChatML template supports "thinking" (<think>...</think>).
        // To avoid emitting think tokens in the visible transcript, we prompt with an empty think block.
        out += "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return out
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
}
