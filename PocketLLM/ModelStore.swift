import Foundation
import Combine

struct ModelDescriptor: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case model
        case mmproj
        case privacyFilter
    }

    enum Category: String, CaseIterable, Equatable, Hashable {
        case llm = "LLM"
        case vlm = "VLM"
        case asr = "ASR"
        case tts = "TTS"
        case privacyFilter = "隐私过滤"
    }

    enum Organization: String, CaseIterable, Equatable, Hashable, Identifiable {
        case qwen
        case google
        case openBMB
        case openAI
        case liquidAI
        case custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .qwen: return "Qwen"
            case .google: return "Google"
            case .liquidAI: return "Liquid AI"
            case .openBMB: return "OpenBMB"
            case .openAI: return "OpenAI"
            case .custom: return "Custom"
            }
        }

        var logoAssetName: String? {
            switch self {
            case .qwen: return "QwenLogo"
            case .google: return "GoogleLogo"
            case .liquidAI: return "LiquidAILogo"
            case .openBMB: return "OpenBMBLogo"
            case .openAI: return "OpenAILogo"
            case .custom: return nil
            }
        }

        var fallbackSymbol: String {
            switch self {
            case .qwen: return "sparkles"
            case .google: return "g.circle"
            case .liquidAI: return "drop.circle"
            case .openBMB: return "cube.transparent"
            case .openAI: return "swirl.circle.righthalf.filled"
            case .custom: return "folder"
            }
        }
    }

    struct Metadata: Equatable {
        var category: Category
        var organization: Organization
        var parameterCount: String
        var modelSize: String
        var releaseMonth: String
        var description: String

        static let custom = Metadata(
            category: .llm,
            organization: .custom,
            parameterCount: "未知",
            modelSize: "未知",
            releaseMonth: "未知",
            description: "Custom GGUF model"
        )
    }

    enum Source: Equatable {
        case remote(url: URL)
        case localFile(url: URL)
    }

    let id: String
    var name: String
    var filename: String
    var kind: Kind
    var pairedMMProjID: String?
    var source: Source
    var metadata: Metadata

    init(
        id: String,
        name: String,
        filename: String,
        kind: Kind = .model,
        pairedMMProjID: String? = nil,
        source: Source,
        metadata: Metadata = .custom
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.kind = kind
        self.pairedMMProjID = pairedMMProjID
        self.source = source
        self.metadata = metadata
    }
}

extension String {
    var quantizationDisplayName: String {
        var name = self
        let replacements = [
            "(Q4_K_M)": "(4bit)",
            "(Q4_K_S)": "(4bit)",
            "(Q4_0)": "(4bit)",
            "(Q4_1)": "(4bit)",
            "(Q5_K_M)": "(5bit)",
            "(Q5_K_S)": "(5bit)",
            "(Q5_0)": "(5bit)",
            "(Q5_1)": "(5bit)",
            "(Q6_K)": "(6bit)",
            "(Q8_0)": "(8bit)",
            "(F16)": "(16bit)",
            "(BF16)": "(16bit)"
        ]

        for (source, replacement) in replacements {
            name = name.replacingOccurrences(of: source, with: replacement)
        }
        return name
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var installed: [ModelDescriptor] = []
    @Published private(set) var catalog: [ModelDescriptor] = []
    @Published var activeModelID: String? {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Self.activeModelKey) }
    }

    @Published var activeMMProjID: String? {
        didSet { UserDefaults.standard.set(activeMMProjID, forKey: Self.activeMMProjKey) }
    }

    @Published var downloadState: [String: DownloadState] = [:]

    private static let privacyFilterID = "openai/privacy-filter"
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var privacyDownloadTasks: [String: Task<Void, Never>] = [:]

    struct DownloadState: Equatable {
        var progress: Double
        var status: Status

        enum Status: Equatable {
            case idle
            case downloading
            case downloaded
            case failed(String)
        }
    }

    private static let activeModelKey = "PocketLLM.activeModelID"
    private static let activeMMProjKey = "PocketLLM.activeMMProjID"

    init() {
        self.activeModelID = UserDefaults.standard.string(forKey: Self.activeModelKey)
        self.activeMMProjID = UserDefaults.standard.string(forKey: Self.activeMMProjKey)
        loadCatalog()
        refreshInstalled()
    }

    func activeModel() -> ModelDescriptor? {
        guard let activeModelID else { return nil }
        return installed.first(where: { $0.id == activeModelID && $0.kind == .model })
    }

    func activeModelURL() -> URL? {
        activeModel()?.localURL
    }

    func activeMMProjURL() -> URL? {
        guard let activeMMProjID else { return nil }
        return installed.first(where: { $0.id == activeMMProjID })?.localURL
    }

    func compatibleActiveMMProjURL() -> URL? {
        guard let model = activeModel(), let expectedMMProjID = model.pairedMMProjID else { return nil }
        guard activeMMProjID == expectedMMProjID else { return nil }
        return installed.first(where: { $0.id == expectedMMProjID && $0.kind == .mmproj })?.localURL
    }

    func activeMMProjCompatibilityError() -> String? {
        guard let model = activeModel(), let expectedMMProjID = model.pairedMMProjID else { return nil }
        guard activeMMProjID != expectedMMProjID else { return nil }
        if downloadState[expectedMMProjID]?.status == .downloading {
            return "The vision projector for \(model.name) is still downloading."
        }
        return "The vision projector for \(model.name) is not installed yet. Download the model again or wait for its dependency to finish."
    }

    func setActiveModel(_ model: ModelDescriptor) {
        guard model.kind == .model else { return }
        activeModelID = model.id

        guard let pairedID = model.pairedMMProjID else {
            activeMMProjID = nil
            return
        }

        if installed.contains(where: { $0.id == pairedID && $0.kind == .mmproj }) {
            activeMMProjID = pairedID
        } else {
            activeMMProjID = nil
            if let paired = catalog.first(where: { $0.id == pairedID && $0.kind == .mmproj }) {
                downloadSingle(paired)
            }
        }
    }

    func setActiveMMProj(_ model: ModelDescriptor) {
        guard model.kind == .mmproj else { return }
        activeMMProjID = model.id
    }

    func clearActiveModel() {
        activeModelID = nil
    }

    func clearActiveMMProj() {
        activeMMProjID = nil
    }

    func refreshInstalled() {
        do {
            let dir = try FileLocations.modelsDirectory(create: true)
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            installed = urls.map { url in
                descriptorForLocalFile(url)
            }

            if isPrivacyFilterInstalled(),
               let privacyFilter = catalog.first(where: { $0.id == Self.privacyFilterID }) {
                installed.append(privacyFilter)
                downloadState[privacyFilter.id] = .init(progress: 1.0, status: .downloaded)
            }

            if let activeModelID, installed.contains(where: { $0.id == activeModelID }) == false {
                self.activeModelID = nil
            }

            if let activeModel = activeModel(), isReadyToSelect(activeModel) == false {
                activeModelID = nil
                activeMMProjID = nil
            }

            if let activeMMProjID, installed.contains(where: { $0.id == activeMMProjID }) == false {
                self.activeMMProjID = nil
            }
        } catch {
            installed = []
        }
    }

    func deleteInstalled(_ model: ModelDescriptor) throws {
        if model.kind == .privacyFilter {
            let directory = try FileLocations.privacyFilterDirectory(create: false)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            downloadState[model.id] = .init(progress: 0, status: .idle)
            refreshInstalled()
            return
        }

        let url = model.localURL
        try FileManager.default.removeItem(at: url)
        if let pairedID = model.pairedMMProjID,
           canDeletePairedMMProj(pairedID, excluding: model.id),
           let paired = installed.first(where: { $0.id == pairedID && $0.kind == .mmproj }),
           FileManager.default.fileExists(atPath: paired.localURL.path) {
            try FileManager.default.removeItem(at: paired.localURL)
        }
        refreshInstalled()
        if activeModelID == model.id {
            activeModelID = nil
        }
        if activeMMProjID == model.id {
            activeMMProjID = nil
        }
    }

    func download(_ model: ModelDescriptor) {
        if model.kind == .privacyFilter {
            downloadPrivacyFilter(model)
            return
        }

        guard model.kind == .model else {
            downloadSingle(model)
            return
        }

        downloadSingle(model)

        if let pairedID = model.pairedMMProjID,
           let paired = catalog.first(where: { $0.id == pairedID && $0.kind == .mmproj }) {
            downloadSingle(paired)
        }
    }

    func cancelDownload(_ model: ModelDescriptor) {
        if model.kind == .privacyFilter {
            privacyDownloadTasks[model.id]?.cancel()
            privacyDownloadTasks[model.id] = nil
            downloadState[model.id] = .init(progress: 0, status: .idle)
            return
        }

        cancelSingleDownload(model.id)

        if let pairedID = model.pairedMMProjID {
            cancelSingleDownload(pairedID)
        }
    }

    private func cancelSingleDownload(_ id: String) {
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        downloadState[id] = .init(progress: 0, status: .idle)
    }

    private func downloadSingle(_ model: ModelDescriptor) {
        guard case let .remote(url) = model.source else { return }
        guard downloadTasks[model.id] == nil else { return }
        let destination = FileLocations.modelFileURL(filename: model.filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            refreshInstalled()
            downloadState[model.id] = .init(progress: 1.0, status: .downloaded)
            return
        }

        downloadState[model.id] = .init(progress: 0.0, status: .downloading)

        let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
            Task { @MainActor in
                self.downloadTasks[model.id] = nil

                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.downloadState[model.id] = .init(progress: 0.0, status: .idle)
                        return
                    }
                    self.downloadState[model.id] = .init(progress: 0.0, status: .failed(error.localizedDescription))
                    return
                }

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let tmp else {
                    self.downloadState[model.id] = .init(progress: 0.0, status: .failed("Server error"))
                    return
                }

                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    try destination.excludeFromBackup()

                    self.downloadState[model.id] = .init(progress: 1.0, status: .downloaded)
                    self.refreshInstalled()

                    if model.kind == .mmproj,
                       let activeModel = self.activeModel(),
                       activeModel.pairedMMProjID == model.id {
                        self.activeMMProjID = model.id
                    }
                } catch {
                    self.downloadState[model.id] = .init(progress: 0.0, status: .failed(error.localizedDescription))
                }
            }
        }

        let observation = task.progress.observe(\Progress.fractionCompleted) { progress, _ in
            Task { @MainActor in
                guard self.downloadState[model.id]?.status == .downloading else { return }
                self.downloadState[model.id]?.progress = progress.fractionCompleted
            }
        }

        // Keep observation alive for task lifetime.
        task.taskDescription = "PocketLLM.download.\(model.id)"
        downloadTasks[model.id] = task
        DownloadObservationStore.shared.set(observation, for: task)

        task.resume()
    }

    private func downloadPrivacyFilter(_ model: ModelDescriptor) {
        guard privacyDownloadTasks[model.id] == nil else { return }

        let task = Task { @MainActor in
            defer { privacyDownloadTasks[model.id] = nil }

            do {
                let modelDirectory = try FileLocations.privacyFilterDirectory(create: true)
                let missing = OpenAIPrivacyFilterModel.artifacts.filter { artifact in
                    FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(artifact.localPath).path) == false
                }

                guard missing.isEmpty == false else {
                    downloadState[model.id] = .init(progress: 1, status: .downloaded)
                    refreshInstalled()
                    return
                }

                for (index, artifact) in missing.enumerated() {
                    try Task.checkCancellation()

                    downloadState[model.id] = .init(
                        progress: Double(index) / Double(missing.count),
                        status: .downloading
                    )

                    let destinationURL = modelDirectory.appendingPathComponent(artifact.localPath)
                    try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let temporaryURL = try await OpenAIPrivacyFilterModel.download(artifact: artifact)

                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                    try destinationURL.excludeFromBackup()
                }

                downloadState[model.id] = .init(progress: 1, status: .downloaded)
                refreshInstalled()
            } catch is CancellationError {
                downloadState[model.id] = .init(progress: 0, status: .idle)
            } catch {
                downloadState[model.id] = .init(progress: 0, status: .failed(error.localizedDescription))
            }
        }

        privacyDownloadTasks[model.id] = task
    }

    func addCustomModel(name: String, urlString: String, filename: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let file = filename ?? (url.lastPathComponent.isEmpty ? "model.gguf" : url.lastPathComponent)
        let id = file
        let model = ModelDescriptor(id: id, name: name, filename: file, source: .remote(url: url))
        if catalog.contains(where: { $0.id == id }) { return }
        catalog.insert(model, at: 0)
    }

    func pairedMMProjStatus(for model: ModelDescriptor) -> String? {
        guard let pairedID = model.pairedMMProjID else { return nil }

        if activeModelID == model.id, activeMMProjID == pairedID {
            return "Vision projector ready"
        }

        if installed.contains(where: { $0.id == pairedID && $0.kind == .mmproj }) {
            return "Vision projector installed"
        }

        if let state = downloadState[pairedID] {
            switch state.status {
            case .downloading:
                return "Vision projector downloading"
            case .failed(let message):
                return "Vision projector failed: \(message)"
            case .downloaded:
                return "Vision projector downloaded"
            case .idle:
                break
            }
        }

        return "Vision projector required"
    }

    func pairedMMProj(for model: ModelDescriptor) -> ModelDescriptor? {
        guard let pairedID = model.pairedMMProjID else { return nil }
        return catalog.first(where: { $0.id == pairedID })
            ?? installed.first(where: { $0.id == pairedID })
    }

    func isReadyToSelect(_ model: ModelDescriptor) -> Bool {
        guard model.kind == .model else { return false }
        guard installed.contains(where: { $0.id == model.id && $0.kind == .model }) else { return false }
        guard let pairedID = model.pairedMMProjID else { return true }
        return installed.contains(where: { $0.id == pairedID && $0.kind == .mmproj })
    }

    func isInstalledForDisplay(_ model: ModelDescriptor) -> Bool {
        switch model.kind {
        case .model:
            return isReadyToSelect(model)
        case .mmproj:
            return installed.contains(where: { $0.id == model.id && $0.kind == .mmproj })
        case .privacyFilter:
            return installed.contains(where: { $0.id == model.id && $0.kind == .privacyFilter })
        }
    }

    func isPartiallyInstalled(_ model: ModelDescriptor) -> Bool {
        guard model.kind == .model, let pairedID = model.pairedMMProjID else { return false }
        let hasModel = installed.contains(where: { $0.id == model.id && $0.kind == .model })
        let hasProjector = installed.contains(where: { $0.id == pairedID && $0.kind == .mmproj })
        return hasModel && hasProjector == false
    }

    func deletePartialDownload(for model: ModelDescriptor) throws {
        guard model.kind == .model else { return }
        var candidates = [model.id]
        if let pairedID = model.pairedMMProjID,
           canDeletePairedMMProj(pairedID, excluding: model.id) {
            candidates.append(pairedID)
        }

        for candidateID in candidates {
            guard let installedModel = installed.first(where: { $0.id == candidateID }) else { continue }
            if FileManager.default.fileExists(atPath: installedModel.localURL.path) {
                try FileManager.default.removeItem(at: installedModel.localURL)
            }
        }
        refreshInstalled()
    }

    private func canDeletePairedMMProj(_ pairedID: String, excluding modelID: String) -> Bool {
        installed.contains { installedModel in
            installedModel.kind == .model
                && installedModel.id != modelID
                && installedModel.pairedMMProjID == pairedID
        } == false
    }

    private func isPrivacyFilterInstalled() -> Bool {
        guard let modelDirectory = try? FileLocations.privacyFilterDirectory(create: false) else { return false }
        return OpenAIPrivacyFilterModel.artifacts.allSatisfy { artifact in
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(artifact.localPath).path)
        }
    }

    private func descriptorForLocalFile(_ url: URL) -> ModelDescriptor {
        let filename = url.lastPathComponent
        if let catalogModel = catalog.first(where: { $0.filename == filename || $0.id == filename }) {
            return ModelDescriptor(
                id: catalogModel.id,
                name: catalogModel.name,
                filename: catalogModel.filename,
                kind: catalogModel.kind,
                pairedMMProjID: catalogModel.pairedMMProjID,
                source: .localFile(url: url),
                metadata: catalogModel.metadata
            )
        }

        let isMMProj = filename.lowercased().contains("mmproj")
        return ModelDescriptor(
            id: filename,
            name: url.deletingPathExtension().lastPathComponent,
            filename: filename,
            kind: isMMProj ? .mmproj : .model,
            source: .localFile(url: url),
            metadata: .custom
        )
    }

    private func loadCatalog() {
        let qwenVLMQ4Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "2B",
            modelSize: "约 1.5 GB",
            releaseMonth: "2026-01",
            description: "Qwen vision-language GGUF with projector dependency"
        )
        let qwenVLMQ8Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "2B",
            modelSize: "约 2.01 GB",
            releaseMonth: "2026-01",
            description: "Qwen vision-language GGUF with projector dependency"
        )
        let qwenVLMBF16Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "2B",
            modelSize: "约 3.78 GB",
            releaseMonth: "2026-01",
            description: "Qwen vision-language GGUF with projector dependency"
        )
        let qwen08BVLMQ4Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "0.8B",
            modelSize: "约 535 MB",
            releaseMonth: "2026-05",
            description: "Qwen3.5 0.8B compact vision-language GGUF with projector dependency"
        )
        let qwen08BVLMQ8Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "0.8B",
            modelSize: "约 812 MB",
            releaseMonth: "2026-05",
            description: "Qwen3.5 0.8B compact vision-language GGUF with projector dependency"
        )
        let qwen08BVLMBF16Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "0.8B",
            modelSize: "约 1.52 GB",
            releaseMonth: "2026-05",
            description: "Qwen3.5 0.8B compact vision-language GGUF with projector dependency"
        )
        let qwen4BVLMQ4Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "4B",
            modelSize: "约 2.74 GB",
            releaseMonth: "2026-03",
            description: "Qwen3.5 4B vision-language GGUF with projector dependency"
        )
        let qwen4BVLMQ8Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "4B",
            modelSize: "约 4.48 GB",
            releaseMonth: "2026-03",
            description: "Qwen3.5 4B vision-language GGUF with projector dependency"
        )
        let qwen4BVLMBF16Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .qwen,
            parameterCount: "4B",
            modelSize: "约 8.42 GB",
            releaseMonth: "2026-03",
            description: "Qwen3.5 4B vision-language GGUF with projector dependency"
        )
        let gemma4E2BMetadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .google,
            parameterCount: "2.3B",
            modelSize: "约 3.11 GB",
            releaseMonth: "2026-04",
            description: "Unsloth GGUF conversion of Google Gemma 4 E2B Instruct VLM"
        )
        let gemma4E4BMetadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .google,
            parameterCount: "4.5B",
            modelSize: "约 4.98 GB",
            releaseMonth: "2026-04",
            description: "Unsloth GGUF conversion of Google Gemma 4 E4B Instruct VLM"
        )
        let lfm25_350MMetadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "350M",
            modelSize: "约 267 MB",
            releaseMonth: "2026-03",
            description: "Liquid AI LFM 2.5 compact GGUF text model"
        )
        let lfm25_350MQ8Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "350M",
            modelSize: "约 379 MB",
            releaseMonth: "2026-03",
            description: "Liquid AI LFM 2.5 compact GGUF text model"
        )
        let lfm25_350M16Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "350M",
            modelSize: "约 711 MB",
            releaseMonth: "2026-03",
            description: "Liquid AI LFM 2.5 compact GGUF text model"
        )
        let lfm25_12BMetadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "1.2B",
            modelSize: "约 731 MB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 Instruct GGUF text model"
        )
        let lfm25_12BQ8Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "1.2B",
            modelSize: "约 1.25 GB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 Instruct GGUF text model"
        )
        let lfm25_12B16Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "1.2B",
            modelSize: "约 2.34 GB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 Instruct GGUF text model"
        )
        let lfm25_12BThinkingMetadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "1.2B",
            modelSize: "约 731 MB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 on-device reasoning GGUF text model"
        )
        let lfm25_12BThinkingQ8Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "1.2B",
            modelSize: "约 1.25 GB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 on-device reasoning GGUF text model"
        )
        let lfm25_12BThinking16Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .liquidAI,
            parameterCount: "1.2B",
            modelSize: "约 2.34 GB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 on-device reasoning GGUF text model"
        )
        let lfm25VL450MMetadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .liquidAI,
            parameterCount: "450M",
            modelSize: "约 219 MB",
            releaseMonth: "2026-04",
            description: "Liquid AI LFM 2.5 VL GGUF vision-language model"
        )
        let lfm25VL450MQ8Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .liquidAI,
            parameterCount: "450M",
            modelSize: "约 379 MB",
            releaseMonth: "2026-04",
            description: "Liquid AI LFM 2.5 VL GGUF vision-language model"
        )
        let lfm25VL450M16Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .liquidAI,
            parameterCount: "450M",
            modelSize: "约 711 MB",
            releaseMonth: "2026-04",
            description: "Liquid AI LFM 2.5 VL GGUF vision-language model"
        )
        let lfm25VL16BMetadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .liquidAI,
            parameterCount: "1.6B",
            modelSize: "约 696 MB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 VL GGUF vision-language model"
        )
        let lfm25VL16BQ8Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .liquidAI,
            parameterCount: "1.6B",
            modelSize: "约 1.25 GB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 VL GGUF vision-language model"
        )
        let lfm25VL16B16Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .liquidAI,
            parameterCount: "1.6B",
            modelSize: "约 2.34 GB",
            releaseMonth: "2026-01",
            description: "Liquid AI LFM 2.5 VL GGUF vision-language model"
        )
        let miniCPMV46Q4Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .openBMB,
            parameterCount: "1.3B",
            modelSize: "约 529 MB",
            releaseMonth: "2026-05",
            description: "MiniCPM-V 4.6 multimodal model for image understanding"
        )
        let miniCPMV46Q8Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .openBMB,
            parameterCount: "1.3B",
            modelSize: "约 812 MB",
            releaseMonth: "2026-05",
            description: "MiniCPM-V 4.6 multimodal model for image understanding"
        )
        let miniCPMV46F16Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .openBMB,
            parameterCount: "1.3B",
            modelSize: "约 1.52 GB",
            releaseMonth: "2026-05",
            description: "MiniCPM-V 4.6 multimodal model for image understanding"
        )
        let miniCPMV45Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .openBMB,
            parameterCount: "8.7B",
            modelSize: "约 5.03 GB",
            releaseMonth: "2025-08",
            description: "MiniCPM-V 4.5 multimodal GGUF model"
        )
        let miniCPM41Metadata = ModelDescriptor.Metadata(
            category: .llm,
            organization: .openBMB,
            parameterCount: "8B",
            modelSize: "约 4.7 GB",
            releaseMonth: "2026-01",
            description: "MiniCPM4.1 compact text model"
        )
        let miniCPMV4Metadata = ModelDescriptor.Metadata(
            category: .vlm,
            organization: .openBMB,
            parameterCount: "4.1B",
            modelSize: "约 2.19 GB",
            releaseMonth: "2025-06",
            description: "MiniCPM-V 4.0 multimodal GGUF model"
        )
        let privacyMetadata = ModelDescriptor.Metadata(
            category: .privacyFilter,
            organization: .openAI,
            parameterCount: "124M",
            modelSize: "约 130 MB",
            releaseMonth: "2025-05",
            description: "OpenAI local privacy redaction ONNX model"
        )

        // Default catalog (safe mirror link)
        let qwen = ModelDescriptor(
            id: "Qwen3.5-2B-Q4_K_M.gguf",
            name: "Qwen3.5-2B (Q4_K_M)",
            filename: "Qwen3.5-2B-Q4_K_M.gguf",
            pairedMMProjID: "mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!),
            metadata: qwenVLMQ4Metadata
        )

        let qwenQ8 = ModelDescriptor(
            id: "Qwen3.5-2B-Q8_0.gguf",
            name: "Qwen3.5-2B (Q8_0)",
            filename: "Qwen3.5-2B-Q8_0.gguf",
            pairedMMProjID: "mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q8_0.gguf")!),
            metadata: qwenVLMQ8Metadata
        )

        let qwenBF16 = ModelDescriptor(
            id: "Qwen3.5-2B-BF16.gguf",
            name: "Qwen3.5-2B (BF16)",
            filename: "Qwen3.5-2B-BF16.gguf",
            pairedMMProjID: "mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-BF16.gguf")!),
            metadata: qwenVLMBF16Metadata
        )

        let qwenMMProj = ModelDescriptor(
            id: "mmproj-F16.gguf",
            name: "Qwen3.5 mmproj (F16)",
            filename: "mmproj-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/mmproj-F16.gguf")!),
            metadata: qwenVLMQ4Metadata
        )

        let qwen08BQ4 = ModelDescriptor(
            id: "Qwen3.5-0.8B-Q4_K_M.gguf",
            name: "Qwen3.5-0.8B (Q4_K_M)",
            filename: "Qwen3.5-0.8B-Q4_K_M.gguf",
            pairedMMProjID: "Qwen3.5-0.8B-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!),
            metadata: qwen08BVLMQ4Metadata
        )

        let qwen08BQ8 = ModelDescriptor(
            id: "Qwen3.5-0.8B-Q8_0.gguf",
            name: "Qwen3.5-0.8B (Q8_0)",
            filename: "Qwen3.5-0.8B-Q8_0.gguf",
            pairedMMProjID: "Qwen3.5-0.8B-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q8_0.gguf")!),
            metadata: qwen08BVLMQ8Metadata
        )

        let qwen08BBF16 = ModelDescriptor(
            id: "Qwen3.5-0.8B-BF16.gguf",
            name: "Qwen3.5-0.8B (BF16)",
            filename: "Qwen3.5-0.8B-BF16.gguf",
            pairedMMProjID: "Qwen3.5-0.8B-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-BF16.gguf")!),
            metadata: qwen08BVLMBF16Metadata
        )

        let qwen08BMMProj = ModelDescriptor(
            id: "Qwen3.5-0.8B-mmproj-F16.gguf",
            name: "Qwen3.5-0.8B mmproj (F16)",
            filename: "Qwen3.5-0.8B-mmproj-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/mmproj-F16.gguf")!),
            metadata: qwen08BVLMQ4Metadata
        )

        let qwen4BQ4 = ModelDescriptor(
            id: "Qwen3.5-4B-Q4_K_M.gguf",
            name: "Qwen3.5-4B (Q4_K_M)",
            filename: "Qwen3.5-4B-Q4_K_M.gguf",
            pairedMMProjID: "Qwen3.5-4B-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!),
            metadata: qwen4BVLMQ4Metadata
        )

        let qwen4BQ8 = ModelDescriptor(
            id: "Qwen3.5-4B-Q8_0.gguf",
            name: "Qwen3.5-4B (Q8_0)",
            filename: "Qwen3.5-4B-Q8_0.gguf",
            pairedMMProjID: "Qwen3.5-4B-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q8_0.gguf")!),
            metadata: qwen4BVLMQ8Metadata
        )

        let qwen4BBF16 = ModelDescriptor(
            id: "Qwen3.5-4B-BF16.gguf",
            name: "Qwen3.5-4B (BF16)",
            filename: "Qwen3.5-4B-BF16.gguf",
            pairedMMProjID: "Qwen3.5-4B-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-BF16.gguf")!),
            metadata: qwen4BVLMBF16Metadata
        )

        let qwen4BMMProj = ModelDescriptor(
            id: "Qwen3.5-4B-mmproj-F16.gguf",
            name: "Qwen3.5-4B mmproj (F16)",
            filename: "Qwen3.5-4B-mmproj-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-4B-GGUF/resolve/main/mmproj-F16.gguf")!),
            metadata: qwen4BVLMQ4Metadata
        )

        let gemma4E2B = ModelDescriptor(
            id: "gemma-4-E2B-it-Q4_K_M.gguf",
            name: "Gemma-4-E2B-it（4bit）",
            filename: "gemma-4-E2B-it-Q4_K_M.gguf",
            pairedMMProjID: "gemma-4-E2B-it-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!),
            metadata: gemma4E2BMetadata
        )

        let gemma4E2BMMProj = ModelDescriptor(
            id: "gemma-4-E2B-it-mmproj-F16.gguf",
            name: "Gemma-4-E2B-it mmproj (F16)",
            filename: "gemma-4-E2B-it-mmproj-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf")!),
            metadata: gemma4E2BMetadata
        )

        let gemma4E4B = ModelDescriptor(
            id: "gemma-4-E4B-it-Q4_K_M.gguf",
            name: "Gemma-4-E4B-it（4bit）",
            filename: "gemma-4-E4B-it-Q4_K_M.gguf",
            pairedMMProjID: "gemma-4-E4B-it-mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!),
            metadata: gemma4E4BMetadata
        )

        let gemma4E4BMMProj = ModelDescriptor(
            id: "gemma-4-E4B-it-mmproj-F16.gguf",
            name: "Gemma-4-E4B-it mmproj (F16)",
            filename: "gemma-4-E4B-it-mmproj-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-F16.gguf")!),
            metadata: gemma4E4BMetadata
        )

        let lfm25_350M = ModelDescriptor(
            id: "LFM2.5-350M-Q4_K_M.gguf",
            name: "LFM2.5-350M (Q4_K_M)",
            filename: "LFM2.5-350M-Q4_K_M.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-350M-GGUF/resolve/main/LFM2.5-350M-Q4_K_M.gguf")!),
            metadata: lfm25_350MMetadata
        )

        let lfm25_350MQ8 = ModelDescriptor(
            id: "LFM2.5-350M-Q8_0.gguf",
            name: "LFM2.5-350M (Q8_0)",
            filename: "LFM2.5-350M-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-350M-GGUF/resolve/main/LFM2.5-350M-Q8_0.gguf")!),
            metadata: lfm25_350MQ8Metadata
        )

        let lfm25_350M16 = ModelDescriptor(
            id: "LFM2.5-350M-BF16.gguf",
            name: "LFM2.5-350M (BF16)",
            filename: "LFM2.5-350M-BF16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-350M-GGUF/resolve/main/LFM2.5-350M-BF16.gguf")!),
            metadata: lfm25_350M16Metadata
        )

        let lfm25_12B = ModelDescriptor(
            id: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
            name: "LFM2.5-1.2B-Instruct (Q4_K_M)",
            filename: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf")!),
            metadata: lfm25_12BMetadata
        )

        let lfm25_12BQ8 = ModelDescriptor(
            id: "LFM2.5-1.2B-Instruct-Q8_0.gguf",
            name: "LFM2.5-1.2B-Instruct (Q8_0)",
            filename: "LFM2.5-1.2B-Instruct-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q8_0.gguf")!),
            metadata: lfm25_12BQ8Metadata
        )

        let lfm25_12B16 = ModelDescriptor(
            id: "LFM2.5-1.2B-Instruct-BF16.gguf",
            name: "LFM2.5-1.2B-Instruct (BF16)",
            filename: "LFM2.5-1.2B-Instruct-BF16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-BF16.gguf")!),
            metadata: lfm25_12B16Metadata
        )

        let lfm25_12BThinking = ModelDescriptor(
            id: "LFM2.5-1.2B-Thinking-Q4_K_M.gguf",
            name: "LFM2.5-1.2B-Thinking (Q4_K_M)",
            filename: "LFM2.5-1.2B-Thinking-Q4_K_M.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q4_K_M.gguf")!),
            metadata: lfm25_12BThinkingMetadata
        )

        let lfm25_12BThinkingQ8 = ModelDescriptor(
            id: "LFM2.5-1.2B-Thinking-Q8_0.gguf",
            name: "LFM2.5-1.2B-Thinking (Q8_0)",
            filename: "LFM2.5-1.2B-Thinking-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q8_0.gguf")!),
            metadata: lfm25_12BThinkingQ8Metadata
        )

        let lfm25_12BThinking16 = ModelDescriptor(
            id: "LFM2.5-1.2B-Thinking-BF16.gguf",
            name: "LFM2.5-1.2B-Thinking (BF16)",
            filename: "LFM2.5-1.2B-Thinking-BF16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-BF16.gguf")!),
            metadata: lfm25_12BThinking16Metadata
        )

        let lfm25VL450M = ModelDescriptor(
            id: "LFM2.5-VL-450M-Q4_0.gguf",
            name: "LFM2.5‑VL-450M (Q4_0)",
            filename: "LFM2.5-VL-450M-Q4_0.gguf",
            pairedMMProjID: "mmproj-LFM2.5-VL-450m-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-Q4_0.gguf")!),
            metadata: lfm25VL450MMetadata
        )

        let lfm25VL450MQ8 = ModelDescriptor(
            id: "LFM2.5-VL-450M-Q8_0.gguf",
            name: "LFM2.5‑VL-450M (Q8_0)",
            filename: "LFM2.5-VL-450M-Q8_0.gguf",
            pairedMMProjID: "mmproj-LFM2.5-VL-450m-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-Q8_0.gguf")!),
            metadata: lfm25VL450MQ8Metadata
        )

        let lfm25VL450M16 = ModelDescriptor(
            id: "LFM2.5-VL-450M-F16.gguf",
            name: "LFM2.5‑VL-450M (F16)",
            filename: "LFM2.5-VL-450M-F16.gguf",
            pairedMMProjID: "mmproj-LFM2.5-VL-450m-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf")!),
            metadata: lfm25VL450M16Metadata
        )

        let lfm25VL450MMMProj = ModelDescriptor(
            id: "mmproj-LFM2.5-VL-450m-Q8_0.gguf",
            name: "LFM2.5‑VL-450M mmproj (Q8_0)",
            filename: "mmproj-LFM2.5-VL-450m-Q8_0.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-Q8_0.gguf")!),
            metadata: lfm25VL450MMetadata
        )

        let lfm25VL450MMMProj16 = ModelDescriptor(
            id: "mmproj-LFM2.5-VL-450m-F16.gguf",
            name: "LFM2.5‑VL-450M mmproj (F16)",
            filename: "mmproj-LFM2.5-VL-450m-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf")!),
            metadata: lfm25VL450M16Metadata
        )

        let lfm25VL16B = ModelDescriptor(
            id: "LFM2.5-VL-1.6B-Q4_0.gguf",
            name: "LFM2.5‑VL-1.6B (Q4_0)",
            filename: "LFM2.5-VL-1.6B-Q4_0.gguf",
            pairedMMProjID: "mmproj-LFM2.5-VL-1.6b-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-Q4_0.gguf")!),
            metadata: lfm25VL16BMetadata
        )

        let lfm25VL16BQ8 = ModelDescriptor(
            id: "LFM2.5-VL-1.6B-Q8_0.gguf",
            name: "LFM2.5‑VL-1.6B (Q8_0)",
            filename: "LFM2.5-VL-1.6B-Q8_0.gguf",
            pairedMMProjID: "mmproj-LFM2.5-VL-1.6b-Q8_0.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-Q8_0.gguf")!),
            metadata: lfm25VL16BQ8Metadata
        )

        let lfm25VL16B16 = ModelDescriptor(
            id: "LFM2.5-VL-1.6B-BF16.gguf",
            name: "LFM2.5‑VL-1.6B (BF16)",
            filename: "LFM2.5-VL-1.6B-BF16.gguf",
            pairedMMProjID: "mmproj-LFM2.5-VL-1.6b-BF16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-BF16.gguf")!),
            metadata: lfm25VL16B16Metadata
        )

        let lfm25VL16BMMProj = ModelDescriptor(
            id: "mmproj-LFM2.5-VL-1.6b-Q8_0.gguf",
            name: "LFM2.5‑VL-1.6B mmproj (Q8_0)",
            filename: "mmproj-LFM2.5-VL-1.6b-Q8_0.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/mmproj-LFM2.5-VL-1.6b-Q8_0.gguf")!),
            metadata: lfm25VL16BMetadata
        )

        let lfm25VL16BMMProj16 = ModelDescriptor(
            id: "mmproj-LFM2.5-VL-1.6b-BF16.gguf",
            name: "LFM2.5‑VL-1.6B mmproj (BF16)",
            filename: "mmproj-LFM2.5-VL-1.6b-BF16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/mmproj-LFM2.5-VL-1.6b-BF16.gguf")!),
            metadata: lfm25VL16B16Metadata
        )

        let miniCPM46 = ModelDescriptor(
            id: "MiniCPM-V-4_6-Q4_K_M.gguf",
            name: "MiniCPM-V 4.6 (Q4_K_M)",
            filename: "MiniCPM-V-4_6-Q4_K_M.gguf",
            pairedMMProjID: "MiniCPM-V-4_6-mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4.6-gguf/resolve/main/MiniCPM-V-4_6-Q4_K_M.gguf")!),
            metadata: miniCPMV46Q4Metadata
        )

        let miniCPM46Q8 = ModelDescriptor(
            id: "MiniCPM-V-4_6-Q8_0.gguf",
            name: "MiniCPM-V 4.6 (Q8_0)",
            filename: "MiniCPM-V-4_6-Q8_0.gguf",
            pairedMMProjID: "MiniCPM-V-4_6-mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4.6-gguf/resolve/main/MiniCPM-V-4_6-Q8_0.gguf")!),
            metadata: miniCPMV46Q8Metadata
        )

        let miniCPM46F16 = ModelDescriptor(
            id: "MiniCPM-V-4_6-F16.gguf",
            name: "MiniCPM-V 4.6 (F16)",
            filename: "MiniCPM-V-4_6-F16.gguf",
            pairedMMProjID: "MiniCPM-V-4_6-mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4.6-gguf/resolve/main/MiniCPM-V-4_6-F16.gguf")!),
            metadata: miniCPMV46F16Metadata
        )

        let miniCPM46MMProj = ModelDescriptor(
            id: "MiniCPM-V-4_6-mmproj-model-f16.gguf",
            name: "MiniCPM-V 4.6 mmproj (F16)",
            filename: "MiniCPM-V-4_6-mmproj-model-f16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4.6-gguf/resolve/main/mmproj-model-f16.gguf")!),
            metadata: miniCPMV46Q4Metadata
        )

        let miniCPM = ModelDescriptor(
            id: "MiniCPM-V-4_5-Q4_K_M.gguf",
            name: "MiniCPM-V 4.5 (Q4_K_M)",
            filename: "MiniCPM-V-4_5-Q4_K_M.gguf",
            pairedMMProjID: "mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4_5-gguf/resolve/main/MiniCPM-V-4_5-Q4_K_M.gguf")!),
            metadata: miniCPMV45Metadata
        )

        let miniCPM41 = ModelDescriptor(
            id: "MiniCPM4.1-8B-Q4_K_M.gguf",
            name: "MiniCPM4.1-8B (Q4_K_M)",
            filename: "MiniCPM4.1-8B-Q4_K_M.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM4.1-8B-GGUF/resolve/main/MiniCPM4.1-8B-Q4_K_M.gguf")!),
            metadata: miniCPM41Metadata
        )

        let miniCPMV4 = ModelDescriptor(
            id: "MiniCPM-V4-Q4_K_M.gguf",
            name: "MiniCPM-V 4.0 (Q4_K_M)",
            filename: "MiniCPM-V4-Q4_K_M.gguf",
            pairedMMProjID: "MiniCPM-V4-mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4-gguf/resolve/main/ggml-model-Q4_K_M.gguf")!),
            metadata: miniCPMV4Metadata
        )

        let miniCPMV4MMProj = ModelDescriptor(
            id: "MiniCPM-V4-mmproj-model-f16.gguf",
            name: "MiniCPM-V 4.0 mmproj (F16)",
            filename: "MiniCPM-V4-mmproj-model-f16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4-gguf/resolve/main/mmproj-model-f16.gguf")!),
            metadata: miniCPMV4Metadata
        )

        let miniCPMMMProj = ModelDescriptor(
            id: "mmproj-model-f16.gguf",
            name: "MiniCPM-V 4.5 mmproj (F16)",
            filename: "mmproj-model-f16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4_5-gguf/resolve/main/mmproj-model-f16.gguf")!),
            metadata: miniCPMV45Metadata
        )

        let privacyFilter = ModelDescriptor(
            id: Self.privacyFilterID,
            name: "OpenAI Privacy Filter",
            filename: "onnx/model_q4.onnx",
            kind: .privacyFilter,
            source: .remote(url: URL(string: "https://hf-mirror.com/openai/privacy-filter")!),
            metadata: privacyMetadata
        )

        catalog = [qwen, qwenQ8, qwenBF16, qwenMMProj, qwen08BQ4, qwen08BQ8, qwen08BBF16, qwen08BMMProj, qwen4BQ4, qwen4BQ8, qwen4BBF16, qwen4BMMProj, gemma4E2B, gemma4E2BMMProj, gemma4E4B, gemma4E4BMMProj, lfm25_350M, lfm25_350MQ8, lfm25_350M16, lfm25_12B, lfm25_12BQ8, lfm25_12B16, lfm25_12BThinking, lfm25_12BThinkingQ8, lfm25_12BThinking16, lfm25VL450M, lfm25VL450MQ8, lfm25VL450M16, lfm25VL450MMMProj, lfm25VL450MMMProj16, lfm25VL16B, lfm25VL16BQ8, lfm25VL16B16, lfm25VL16BMMProj, lfm25VL16BMMProj16, miniCPM46, miniCPM46Q8, miniCPM46F16, miniCPM46MMProj, miniCPM, miniCPM41, miniCPMV4, miniCPMV4MMProj, miniCPMMMProj, privacyFilter]
    }

}

extension ModelDescriptor {
    var localURL: URL {
        switch source {
        case .localFile(let url):
            return url
        case .remote:
            return FileLocations.modelFileURL(filename: filename)
        }
    }

    var isMiniCPMV4: Bool {
        let haystack = "\(id) \(filename) \(name)".lowercased()
        return haystack.contains("minicpm-v4")
            || haystack.contains("minicpm-v-4")
            || haystack.contains("minicpm v4")
            || haystack.contains("minicpm-v 4")
    }

    var isMiniCPMV46: Bool {
        let haystack = "\(id) \(filename) \(name)".lowercased()
        return haystack.contains("minicpm-v-4_6")
            || haystack.contains("minicpm-v 4.6")
            || haystack.contains("minicpm-v-4.6")
            || haystack.contains("minicpm-v 4_6")
    }

    var isGemma4: Bool {
        let haystack = "\(id) \(filename) \(name)".lowercased()
        return haystack.contains("gemma-4-e2b") || haystack.contains("gemma-4-e4b")
    }

    var isQwen35VLM: Bool {
        let haystack = "\(id) \(filename) \(name)".lowercased()
        return metadata.category == .vlm && haystack.contains("qwen3.5")
    }
}

private final class DownloadObservationStore {
    static let shared = DownloadObservationStore()
    private var lock = NSLock()
    private var observations: [Int: NSKeyValueObservation] = [:]

    func set(_ observation: NSKeyValueObservation, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        observations[task.taskIdentifier] = observation
    }
}
