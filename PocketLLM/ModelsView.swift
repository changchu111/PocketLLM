import SwiftUI

struct ModelsView: View {
    @ObservedObject var modelStore: ModelStore
    @State private var customName: String = "Custom Model"
    @State private var customURL: String = ""
    @State private var modelPendingDeletion: ModelDescriptor?
    @State private var showingDeleteConfirmation = false

    private var installedModels: [ModelDescriptor] {
        modelStore.installed
    }

    private var downloadableModels: [ModelDescriptor] {
        modelStore.catalog
    }

    var body: some View {
        NavigationStack {
            List {
                activeSection
                activeMMProjSection
                installedSection
                downloadSection
                customSection
            }
            .navigationTitle("Models")
            .confirmationDialog("Delete downloaded model?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button(deleteButtonTitle, role: .destructive) {
                    if let model = modelPendingDeletion {
                        try? modelStore.deleteInstalled(model)
                    }
                    modelPendingDeletion = nil
                    showingDeleteConfirmation = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        modelStore.refreshInstalled()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var activeSection: some View {
        Section("Active") {
            if let activeID = modelStore.activeModelID,
               let active = modelStore.installed.first(where: { $0.id == activeID }) {
                HStack {
                    Text(active.name)
                    Spacer()
                    Button("Cancel") {
                        modelStore.clearActiveModel()
                    }
                    .font(.caption)
                }
            } else {
                Text("No model selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeMMProjSection: some View {
        Section("Active mmproj") {
            if let activeID = modelStore.activeMMProjID,
               let active = modelStore.installed.first(where: { $0.id == activeID }) {
                HStack {
                    Text(active.name)
                    Spacer()
                    Button("Cancel") {
                        modelStore.clearActiveMMProj()
                    }
                    .font(.caption)
                }
            } else {
                Text("No mmproj selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var installedSection: some View {
        Section("Installed") {
            if installedModels.isEmpty {
                Text("No installed models")
                    .foregroundStyle(.secondary)
            }

            ForEach(installedModels) { model in
                InstalledModelRow(
                    model: model,
                    isSelected: isSelected(model),
                    onSelect: { select(model) },
                    onDelete: {
                        modelPendingDeletion = model
                        showingDeleteConfirmation = true
                    }
                )
            }
        }
    }

    private var downloadSection: some View {
        Section("Download") {
            ForEach(downloadableModels) { model in
                DownloadModelRow(
                    model: model,
                    isInstalled: modelStore.installed.contains(where: { $0.id == model.id }),
                    downloadState: modelStore.downloadState[model.id],
                    onSelect: { selectInstalledModel(withID: model.id) },
                    onDownload: { modelStore.download(model) }
                )
            }
        }
    }

    private var customSection: some View {
        Section("Custom") {
            TextField("Name", text: $customName)
            TextField("Direct .gguf URL", text: $customURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Add to download list") {
                modelStore.addCustomModel(name: customName, urlString: customURL)
                customURL = ""
            }
            .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func selectInstalledModel(withID id: String) {
        guard let installed = modelStore.installed.first(where: { $0.id == id }) else { return }
        select(installed)
    }

    private func select(_ model: ModelDescriptor) {
        if model.kind == .mmproj {
            modelStore.setActiveMMProj(model)
        } else {
            modelStore.setActiveModel(model)
        }
    }

    private func isSelected(_ model: ModelDescriptor) -> Bool {
        if model.kind == .model {
            return modelStore.activeModelID == model.id
        }
        return modelStore.activeMMProjID == model.id
    }

    private var deleteButtonTitle: String {
        if let model = modelPendingDeletion {
            return "Delete \(model.name)"
        }
        return "Delete"
    }

    private var deleteMessage: String {
        if let model = modelPendingDeletion {
            return "This removes \(model.filename) from this iPhone and frees storage space. You can download it again later."
        }
        return "This removes the downloaded model from this iPhone and frees storage space."
    }
}

private struct InstalledModelRow: View {
    let model: ModelDescriptor
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                Text(model.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Text("Selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct DownloadModelRow: View {
    let model: ModelDescriptor
    let isInstalled: Bool
    let downloadState: ModelStore.DownloadState?
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.name)
            Text(model.filename)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if isInstalled {
                    Button("Select", action: onSelect)
                } else {
                    Button("Download", action: onDownload)
                }

                Spacer()

                if let state = downloadState {
                    switch state.status {
                    case .downloading:
                        ProgressView(value: state.progress)
                            .frame(width: 120)
                    case .downloaded:
                        Text("Downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .idle:
                        EmptyView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
