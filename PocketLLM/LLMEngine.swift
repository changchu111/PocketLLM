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
    @Published var messages: [ChatMessage] = [
        ChatMessage(
            role: .system,
            text: "You are a helpful assistant. Reply in Markdown. Use explicit line breaks: put each bullet/list item on its own line. Do not output <think> blocks."
        )
    ]
    @Published var draft: String = ""
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var streamingAssistantID: UUID?
    @Published var pendingImage: PlatformImage?

    private let modelStore: ModelStore
    private let settings: GenerationSettings
    private let engine = LLMEngine()

    private var generationTask: Task<Void, Never>?

    init(modelStore: ModelStore, settings: GenerationSettings) {
        self.modelStore = modelStore
        self.settings = settings
    }

    func setPendingImage(_ image: PlatformImage) {
        pendingImage = image
    }

    func clearPendingImage() {
        pendingImage = nil
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil else { return }
        draft = ""
        errorMessage = nil

        stop()

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
        let mmprojURL = imageURL != nil ? modelStore.activeMMProjURL() : nil
        if imageURL != nil, mmprojURL == nil {
            errorMessage = "Download and select an mmproj model first (Models → mmproj-F16.gguf)."
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

                let prompt = PromptBuilder.buildPrompt(from: promptSnapshot, activeImageMessageID: imageURL != nil ? userMessageID : nil)
                try await engine.generate(prompt: prompt, imageURL: imageURL, maxNewTokens: settings.maxNewTokens) { token in
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

    func clearChat() {
        stop()
        messages = [
            ChatMessage(
                role: .system,
                text: "You are a helpful assistant. Reply in Markdown. Use explicit line breaks: put each bullet/list item on its own line. Do not output <think> blocks."
            )
        ]
        errorMessage = nil
        streamingAssistantID = nil
        pendingImage = nil
    }

    private func persistImageAttachment(_ image: UIImage) throws -> ChatAttachment {
        let uuid = UUID().uuidString
        let filename = "\(uuid).jpg"
        let url = FileLocations.attachmentFileURL(filename: filename)

        // Multimodal image tokens grow quickly with resolution.
        // Keep images smaller on iPhone to avoid huge mtmd/KV allocations.
        let scaled = image.scaledDown(maxDimension: 384)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "PocketLLM", code: 2, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }

        try data.write(to: url, options: .atomic)
        try url.excludeFromBackup()

        return ChatAttachment(type: .image, localPath: url.path)
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

    func generate(prompt: String, imageURL: URL?, maxNewTokens: Int32, onToken: @MainActor @Sendable (String) async -> Void) async throws {
        guard let ctx else { throw NSError(domain: "PocketLLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }
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
                let token = await ctx.completion_loop()
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

            // Flush remaining content, trimming any stop artifacts.
            if !pending.isEmpty {
                let cleaned = Self.trimStopArtifacts(pending)
                if !cleaned.isEmpty {
                    await onToken(cleaned)
                }
            }
            await ctx.clear()
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
        for artifact in ["<|im_end|>", "<|im_start|>"] {
            if let r = out.range(of: artifact) {
                out.removeSubrange(r.lowerBound..<out.endIndex)
            }
        }
        return out
    }

    func stop() async {
        await ctx?.requestStop()
    }
}

enum PromptBuilder {
    static func buildPrompt(from messages: [ChatMessage], activeImageMessageID: UUID? = nil) -> String {
        // Minimal ChatML-like prompt that works reasonably across many instruct-ish models.
        // If you later switch to a strictly-instruct GGUF, you can replace this with that model's template.
        let recent = messages.filter { $0.role != .system }
        let system = messages.first(where: { $0.role == .system })?.text ?? "You are a helpful assistant."

        var out = "<|im_start|>system\n\(system)\n<|im_end|>\n"
        for m in recent {
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
            case .assistant:
                out += "<|im_start|>assistant\n\(m.text)\n<|im_end|>\n"
            case .system:
                break
            }
        }
        // Qwen3.5 ChatML template supports "thinking" (<think>...</think>).
        // To avoid emitting think tokens in the visible transcript, we prompt with an empty think block.
        out += "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return out
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
