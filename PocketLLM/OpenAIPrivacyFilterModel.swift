import Foundation
import OnnxRuntimeBindings
import Tokenizers

actor OpenAIPrivacyFilterModel {
    enum ModelState: Equatable {
        case idle
        case downloading(Double, String)
        case loading
        case ready
        case failed(String)
    }

    private struct Artifact {
        let remotePath: String
        let localPath: String
    }

    private static let repoBaseURLs = [
        URL(string: "https://hf-mirror.com/openai/privacy-filter/resolve/main")!,
        URL(string: "https://huggingface.co/openai/privacy-filter/resolve/main")!
    ]
    private static let artifacts: [Artifact] = [
        Artifact(remotePath: "config.json", localPath: "config.json"),
        Artifact(remotePath: "tokenizer.json", localPath: "tokenizer.json"),
        Artifact(remotePath: "tokenizer_config.json", localPath: "tokenizer_config.json"),
        Artifact(remotePath: "viterbi_calibration.json", localPath: "viterbi_calibration.json"),
        Artifact(remotePath: "onnx/model_q4.onnx", localPath: "onnx/model_q4.onnx"),
        Artifact(remotePath: "onnx/model_q4.onnx_data", localPath: "onnx/model_q4.onnx_data")
    ]

    private let labels: [String] = [
        "O",
        "B-account_number", "I-account_number", "E-account_number", "S-account_number",
        "B-private_address", "I-private_address", "E-private_address", "S-private_address",
        "B-private_date", "I-private_date", "E-private_date", "S-private_date",
        "B-private_email", "I-private_email", "E-private_email", "S-private_email",
        "B-private_person", "I-private_person", "E-private_person", "S-private_person",
        "B-private_phone", "I-private_phone", "E-private_phone", "S-private_phone",
        "B-private_url", "I-private_url", "E-private_url", "S-private_url",
        "B-secret", "I-secret", "E-secret", "S-secret"
    ]

    private var env: ORTEnv?
    private var session: ORTSession?
    private var tokenizer: (any Tokenizer)?
    private var state: ModelState = .idle

    func currentState() -> ModelState {
        state
    }

    func sanitize(text: String, progress: @Sendable @escaping (ModelState) async -> Void) async throws -> PrivacyFilterResult {
        do {
            try await loadIfNeeded(progress: progress)
        } catch {
            state = .failed(error.localizedDescription)
            await progress(state)
            throw error
        }

        guard let session, let tokenizer else {
            throw NSError(domain: "PocketLLM.PrivacyFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Privacy filter model is not loaded."])
        }

        let inputIDs = tokenizer.encode(text: text).map(Int64.init)
        guard inputIDs.isEmpty == false else {
            return .passthrough(text)
        }

        let attentionMask = [Int64](repeating: 1, count: inputIDs.count)
        let inputShape = [NSNumber(value: 1), NSNumber(value: inputIDs.count)]
        let inputTensor = try ORTValue(
            tensorData: Self.mutableData(from: inputIDs),
            elementType: .int64,
            shape: inputShape
        )
        let attentionTensor = try ORTValue(
            tensorData: Self.mutableData(from: attentionMask),
            elementType: .int64,
            shape: inputShape
        )

        let outputs = try session.run(
            withInputs: ["input_ids": inputTensor, "attention_mask": attentionTensor],
            outputNames: ["logits"],
            runOptions: nil
        )

        guard let logitsValue = outputs["logits"] else {
            throw NSError(domain: "PocketLLM.PrivacyFilter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Privacy filter model did not return logits."])
        }

        let logitsData = try logitsValue.tensorData() as Data
        let logits = logitsData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let predictedLabels = viterbiLabelIDs(from: logits, tokenCount: inputIDs.count)
        return redact(text: text, tokenIDs: inputIDs.map(Int.init), predictedLabels: predictedLabels, tokenizer: tokenizer)
    }

    private func loadIfNeeded(progress: @Sendable @escaping (ModelState) async -> Void) async throws {
        if case .ready = state, session != nil, tokenizer != nil {
            return
        }

        let modelDirectory = try FileLocations.privacyFilterDirectory(create: true)
        try await downloadMissingArtifacts(to: modelDirectory, progress: progress)

        state = .loading
        await progress(state)

        tokenizer = try await AutoTokenizer.from(modelFolder: modelDirectory)
        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        session = try ORTSession(
            env: env,
            modelPath: modelDirectory.appendingPathComponent("onnx/model_q4.onnx").path,
            sessionOptions: nil
        )

        state = .ready
        await progress(state)
    }

    private func downloadMissingArtifacts(to modelDirectory: URL, progress: @Sendable @escaping (ModelState) async -> Void) async throws {
        let fileManager = FileManager.default
        let missing = Self.artifacts.filter { artifact in
            fileManager.fileExists(atPath: modelDirectory.appendingPathComponent(artifact.localPath).path) == false
        }

        guard missing.isEmpty == false else { return }

        for (index, artifact) in missing.enumerated() {
            let fraction = Double(index) / Double(missing.count)
            state = .downloading(fraction, artifact.localPath)
            await progress(state)

            let destinationURL = modelDirectory.appendingPathComponent(artifact.localPath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let temporaryURL = try await download(artifact: artifact)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            try destinationURL.excludeFromBackup()
        }

        state = .downloading(1.0, "完成")
        await progress(state)
    }

    private func download(artifact: Artifact) async throws -> URL {
        var lastError: Error?

        for baseURL in Self.repoBaseURLs {
            guard let sourceURL = URL(string: "\(baseURL.absoluteString)/\(artifact.remotePath)") else {
                continue
            }
            do {
                var request = URLRequest(url: sourceURL)
                request.timeoutInterval = 30
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "PocketLLM.PrivacyFilter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(artifact.remotePath)."])
                }
                return temporaryURL
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(domain: "PocketLLM.PrivacyFilter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(artifact.remotePath)."])
    }

    private func viterbiLabelIDs(from logits: [Float], tokenCount: Int) -> [Int] {
        let classCount = labels.count
        guard logits.count >= tokenCount * classCount else { return [] }

        let invalidScore = -Float.greatestFiniteMagnitude / 4
        var scores = Array(repeating: invalidScore, count: tokenCount * classCount)
        var backpointers = Array(repeating: 0, count: tokenCount * classCount)

        for labelID in 0..<classCount where canStart(with: labelID) {
            scores[labelID] = logits[labelID]
        }

        guard tokenCount > 1 else {
            return [bestTerminalLabel(in: scores, tokenIndex: 0, classCount: classCount)]
        }

        for tokenIndex in 1..<tokenCount {
            for labelID in 0..<classCount {
                let currentLogit = logits[tokenIndex * classCount + labelID]
                var bestPreviousID = 0
                var bestScore = invalidScore

                for previousID in 0..<classCount where canTransition(from: previousID, to: labelID) {
                    let candidateScore = scores[(tokenIndex - 1) * classCount + previousID] + currentLogit
                    if candidateScore > bestScore {
                        bestScore = candidateScore
                        bestPreviousID = previousID
                    }
                }

                scores[tokenIndex * classCount + labelID] = bestScore
                backpointers[tokenIndex * classCount + labelID] = bestPreviousID
            }
        }

        var result = Array(repeating: 0, count: tokenCount)
        result[tokenCount - 1] = bestTerminalLabel(in: scores, tokenIndex: tokenCount - 1, classCount: classCount)
        stride(from: tokenCount - 1, through: 1, by: -1).forEach { tokenIndex in
            result[tokenIndex - 1] = backpointers[tokenIndex * classCount + result[tokenIndex]]
        }
        return result
    }

    private func redact(text: String, tokenIDs: [Int], predictedLabels: [Int], tokenizer: any Tokenizer) -> PrivacyFilterResult {
        var spans: [(range: Range<String.Index>, kind: PrivacyEntityKind)] = []
        var searchStart = text.startIndex
        var index = 0

        while index < min(tokenIDs.count, predictedLabels.count) {
            let label = labels[predictedLabels[index]]
            guard let kind = entityKind(for: label) else {
                index += 1
                continue
            }

            let startIndex = index
            if labelPrefix(for: label) == "S" {
                index += 1
            } else {
                index += 1
                while index < predictedLabels.count {
                    let nextLabel = labels[predictedLabels[index]]
                    guard entityKind(for: nextLabel) == kind else { break }
                    index += 1
                    if labelPrefix(for: nextLabel) == "E" { break }
                }
            }

            let tokenSlice = Array(tokenIDs[startIndex..<index])
            let decoded = tokenizer.decode(tokens: tokenSlice, skipSpecialTokens: true).trimmingCharacters(in: .whitespacesAndNewlines)
            guard decoded.isEmpty == false,
                  let range = text.range(of: decoded, options: [], range: searchStart..<text.endIndex) else {
                continue
            }
            spans.append((range, kind))
            searchStart = range.upperBound
        }

        guard spans.isEmpty == false else {
            return .passthrough(text)
        }

        var sanitized = text
        for span in spans.reversed() {
            sanitized.replaceSubrange(span.range, with: span.kind.replacementText)
        }

        let grouped = Dictionary(grouping: spans, by: { $0.kind })
        let findings = grouped.map { PrivacyFinding(kind: $0.key, count: $0.value.count) }
            .sorted { $0.kind.displayName < $1.kind.displayName }

        return PrivacyFilterResult(originalText: text, sanitizedText: sanitized, findings: findings)
    }

    private func entityKind(for label: String) -> PrivacyEntityKind? {
        let entity = label.split(separator: "-", maxSplits: 1).last.map(String.init)
        switch entity {
        case "account_number": return .accountNumber
        case "private_address": return .privateAddress
        case "private_date": return .privateDate
        case "private_email": return .email
        case "private_person": return .privatePerson
        case "private_phone": return .phone
        case "private_url": return .url
        case "secret": return .secret
        default: return nil
        }
    }

    private func labelPrefix(for label: String) -> String? {
        guard label != "O" else { return "O" }
        return label.split(separator: "-", maxSplits: 1).first.map(String.init)
    }

    private func canStart(with labelID: Int) -> Bool {
        let prefix = labelPrefix(for: labels[labelID])
        return prefix == "O" || prefix == "B" || prefix == "S"
    }

    private func canEnd(with labelID: Int) -> Bool {
        let prefix = labelPrefix(for: labels[labelID])
        return prefix == "O" || prefix == "E" || prefix == "S"
    }

    private func canTransition(from previousID: Int, to currentID: Int) -> Bool {
        let previousLabel = labels[previousID]
        let currentLabel = labels[currentID]
        let previousPrefix = labelPrefix(for: previousLabel)
        let currentPrefix = labelPrefix(for: currentLabel)

        switch previousPrefix {
        case "O", "E", "S":
            return currentPrefix == "O" || currentPrefix == "B" || currentPrefix == "S"
        case "B", "I":
            return entityKind(for: previousLabel) == entityKind(for: currentLabel)
                && (currentPrefix == "I" || currentPrefix == "E")
        default:
            return false
        }
    }

    private func bestTerminalLabel(in scores: [Float], tokenIndex: Int, classCount: Int) -> Int {
        var bestID = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for labelID in 0..<classCount where canEnd(with: labelID) {
            let score = scores[tokenIndex * classCount + labelID]
            if score > bestScore {
                bestScore = score
                bestID = labelID
            }
        }
        return bestID
    }

    private static func mutableData<T>(from values: [T]) -> NSMutableData {
        values.withUnsafeBufferPointer { buffer in
            NSMutableData(bytes: buffer.baseAddress!, length: values.count * MemoryLayout<T>.stride)
        }
    }
}
