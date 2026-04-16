import Foundation
import Combine

struct ModelDescriptor: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case model
        case mmproj
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

    init(
        id: String,
        name: String,
        filename: String,
        kind: Kind = .model,
        pairedMMProjID: String? = nil,
        source: Source
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.kind = kind
        self.pairedMMProjID = pairedMMProjID
        self.source = source
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
        refreshInstalled()
        loadCatalog()
    }

    func activeModelURL() -> URL? {
        guard let activeModelID else { return nil }
        return installed.first(where: { $0.id == activeModelID })?.localURL
    }

    func activeMMProjURL() -> URL? {
        guard let activeMMProjID else { return nil }
        return installed.first(where: { $0.id == activeMMProjID })?.localURL
    }

    func setActiveModel(_ model: ModelDescriptor) {
        guard model.kind == .model else { return }
        activeModelID = model.id
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

            if let activeModelID, installed.contains(where: { $0.id == activeModelID }) == false {
                self.activeModelID = nil
            }

            if let activeMMProjID, installed.contains(where: { $0.id == activeMMProjID }) == false {
                self.activeMMProjID = nil
            }
        } catch {
            installed = []
        }
    }

    func deleteInstalled(_ model: ModelDescriptor) throws {
        let url = model.localURL
        try FileManager.default.removeItem(at: url)
        refreshInstalled()
        if activeModelID == model.id {
            activeModelID = nil
        }
        if activeMMProjID == model.id {
            activeMMProjID = nil
        }
    }

    func download(_ model: ModelDescriptor) {
        downloadSingle(model)
    }

    private func downloadSingle(_ model: ModelDescriptor) {
        guard case let .remote(url) = model.source else { return }
        let destination = FileLocations.modelFileURL(filename: model.filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            refreshInstalled()
            downloadState[model.id] = .init(progress: 1.0, status: .downloaded)
            return
        }

        downloadState[model.id] = .init(progress: 0.0, status: .downloading)

        let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
            Task { @MainActor in
                if let error {
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
        DownloadObservationStore.shared.set(observation, for: task)

        task.resume()
    }

    func addCustomModel(name: String, urlString: String, filename: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let file = filename ?? (url.lastPathComponent.isEmpty ? "model.gguf" : url.lastPathComponent)
        let id = file
        let model = ModelDescriptor(id: id, name: name, filename: file, source: .remote(url: url))
        if catalog.contains(where: { $0.id == id }) { return }
        catalog.insert(model, at: 0)
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
                source: .localFile(url: url)
            )
        }

        let isMMProj = filename.lowercased().contains("mmproj")
        return ModelDescriptor(
            id: filename,
            name: url.deletingPathExtension().lastPathComponent,
            filename: filename,
            kind: isMMProj ? .mmproj : .model,
            source: .localFile(url: url)
        )
    }

    private func loadCatalog() {
        // Default catalog (safe mirror link)
        let qwen = ModelDescriptor(
            id: "Qwen3.5-2B-Q4_K_M.gguf",
            name: "Qwen3.5-2B (Q4_K_M)",
            filename: "Qwen3.5-2B-Q4_K_M.gguf",
            pairedMMProjID: "mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!)
        )

        let qwenMMProj = ModelDescriptor(
            id: "mmproj-F16.gguf",
            name: "Qwen3.5 mmproj (F16)",
            filename: "mmproj-F16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/mmproj-F16.gguf")!)
        )

        let miniCPM = ModelDescriptor(
            id: "MiniCPM-V-4_5-Q4_K_M.gguf",
            name: "MiniCPM-V 4.5 (Q4_K_M)",
            filename: "MiniCPM-V-4_5-Q4_K_M.gguf",
            pairedMMProjID: "mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4_5-gguf/resolve/main/MiniCPM-V-4_5-Q4_K_M.gguf")!)
        )

        let miniCPMQ40 = ModelDescriptor(
            id: "MiniCPM-V-4_5-Q4_0.gguf",
            name: "MiniCPM-V 4.5 (Q4_0)",
            filename: "MiniCPM-V-4_5-Q4_0.gguf",
            pairedMMProjID: "mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4_5-gguf/resolve/main/MiniCPM-V-4_5-Q4_0.gguf")!)
        )

        let miniCPM41 = ModelDescriptor(
            id: "MiniCPM4.1-8B-Q4_K_M.gguf",
            name: "MiniCPM4.1-8B (Q4_K_M)",
            filename: "MiniCPM4.1-8B-Q4_K_M.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM4.1-8B-GGUF/resolve/main/MiniCPM4.1-8B-Q4_K_M.gguf")!)
        )

        let miniCPMV4 = ModelDescriptor(
            id: "MiniCPM-V4-Q4_K_M.gguf",
            name: "MiniCPM-V4 (Q4_K_M)",
            filename: "MiniCPM-V4-Q4_K_M.gguf",
            pairedMMProjID: "MiniCPM-V4-mmproj-model-f16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4-gguf/resolve/main/ggml-model-Q4_K_M.gguf")!)
        )

        let miniCPMV4MMProj = ModelDescriptor(
            id: "MiniCPM-V4-mmproj-model-f16.gguf",
            name: "MiniCPM-V4 mmproj (F16)",
            filename: "MiniCPM-V4-mmproj-model-f16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4-gguf/resolve/main/mmproj-model-f16.gguf")!)
        )

        let miniCPMMMProj = ModelDescriptor(
            id: "mmproj-model-f16.gguf",
            name: "MiniCPM-V 4.5 mmproj (F16)",
            filename: "mmproj-model-f16.gguf",
            kind: .mmproj,
            source: .remote(url: URL(string: "https://hf-mirror.com/openbmb/MiniCPM-V-4_5-gguf/resolve/main/mmproj-model-f16.gguf")!)
        )

        catalog = [qwen, qwenMMProj, miniCPM, miniCPMQ40, miniCPM41, miniCPMV4, miniCPMV4MMProj, miniCPMMMProj]
    }

}

private extension ModelDescriptor {
    var localURL: URL {
        switch source {
        case .localFile(let url):
            return url
        case .remote:
            return FileLocations.modelFileURL(filename: filename)
        }
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
