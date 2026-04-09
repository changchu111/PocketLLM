import Foundation
import Combine

struct ModelDescriptor: Identifiable, Equatable {
    enum Source: Equatable {
        case remote(url: URL)
        case localFile(url: URL)
    }

    let id: String
    var name: String
    var filename: String
    var source: Source

    init(id: String, name: String, filename: String, source: Source) {
        self.id = id
        self.name = name
        self.filename = filename
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
        activeModelID = model.id
    }

    func setActiveMMProj(_ model: ModelDescriptor) {
        activeMMProjID = model.id
    }

    func refreshInstalled() {
        do {
            let dir = try FileLocations.modelsDirectory(create: true)
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            installed = urls.map { url in
                ModelDescriptor(
                    id: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    filename: url.lastPathComponent,
                    source: .localFile(url: url)
                )
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

    private func loadCatalog() {
        // Default catalog (safe mirror link)
        let qwen = ModelDescriptor(
            id: "Qwen3.5-2B-Q4_K_M.gguf",
            name: "Qwen3.5-2B (Q4_K_M)",
            filename: "Qwen3.5-2B-Q4_K_M.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!)
        )

        let mmproj = ModelDescriptor(
            id: "mmproj-F16.gguf",
            name: "Qwen3.5 mmproj (F16)",
            filename: "mmproj-F16.gguf",
            source: .remote(url: URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/mmproj-F16.gguf")!)
        )

        catalog = [qwen, mmproj]
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
