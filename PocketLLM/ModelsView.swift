import SwiftUI

struct ModelsView: View {
    @ObservedObject var modelStore: ModelStore
    @State private var customName: String = "Custom Model"
    @State private var customURL: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Active") {
                    if let activeID = modelStore.activeModelID,
                       let active = modelStore.installed.first(where: { $0.id == activeID }) {
                        Text(active.name)
                    } else {
                        Text("No model selected")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Active mmproj") {
                    if let activeID = modelStore.activeMMProjID,
                       let active = modelStore.installed.first(where: { $0.id == activeID }) {
                        Text(active.name)
                    } else {
                        Text("No mmproj selected")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Installed") {
                    if modelStore.installed.isEmpty {
                        Text("No installed models")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(modelStore.installed) { model in
                        let isMMProj = model.filename.lowercased().contains("mmproj")
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name)
                                Text(model.filename)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if (!isMMProj && modelStore.activeModelID == model.id) || (isMMProj && modelStore.activeMMProjID == model.id) {
                                Text("Selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isMMProj {
                                modelStore.setActiveMMProj(model)
                            } else {
                                modelStore.setActiveModel(model)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                try? modelStore.deleteInstalled(model)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Download") {
                    ForEach(modelStore.catalog) { model in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.name)
                            Text(model.filename)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                if modelStore.installed.contains(where: { $0.id == model.id }) {
                                    Button("Select") {
                                        if let installed = modelStore.installed.first(where: { $0.id == model.id }) {
                                            if installed.filename.lowercased().contains("mmproj") {
                                                modelStore.setActiveMMProj(installed)
                                            } else {
                                                modelStore.setActiveModel(installed)
                                            }
                                        }
                                    }
                                } else {
                                    Button("Download") {
                                        modelStore.download(model)
                                    }
                                }

                                Spacer()

                                if let state = modelStore.downloadState[model.id] {
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
            .navigationTitle("Models")
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
}
