import SwiftUI

struct ModelsView: View {
    @ObservedObject var modelStore: ModelStore
    @State private var modelPendingDeletion: ModelDescriptor?
    @State private var showingDeleteConfirmation = false
    @State private var partialDownloadPendingDeletion: ModelDescriptor?
    @State private var showingPartialDeleteConfirmation = false
    @State private var selectedCategory: ModelDescriptor.Category = .llm
    @State private var isInstalledExpanded = false
    @State private var expandedOrganizationKeys: Set<String> = Set(
        ModelDescriptor.Category.allCases.flatMap { category in
            ModelDescriptor.Organization.allCases.map { organization in
                "\(category.rawValue).\(organization.rawValue)"
            }
        }
    )

    private var installedModels: [ModelDescriptor] {
        modelStore.installed.filter { model in
            if model.kind == .privacyFilter { return true }
            return model.kind == .model && modelStore.isReadyToSelect(model)
        }
    }

    private var downloadableModels: [ModelDescriptor] {
        modelStore.catalog.filter { $0.kind == .model || $0.kind == .privacyFilter }
    }

    var body: some View {
        NavigationStack {
            List {
                installedSection
                categorySelectorSection
                selectedCatalogSection
            }
            .listSectionSpacing(10)
            .navigationTitle("模型")
            .confirmationDialog("删除已下载模型？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button(deleteButtonTitle, role: .destructive) {
                    if let model = modelPendingDeletion {
                        try? modelStore.deleteInstalled(model)
                    }
                    modelPendingDeletion = nil
                    showingDeleteConfirmation = false
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .confirmationDialog("移除未完成下载？", isPresented: $showingPartialDeleteConfirmation, titleVisibility: .visible) {
                Button(partialDeleteButtonTitle, role: .destructive) {
                    if let model = partialDownloadPendingDeletion {
                        try? modelStore.deletePartialDownload(for: model)
                    }
                    partialDownloadPendingDeletion = nil
                    showingPartialDeleteConfirmation = false
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除该模型未完成的本地文件并释放存储空间，之后可以重新下载。")
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

    private var installedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isInstalledExpanded) {
                if installedModels.isEmpty {
                    Text("暂无已安装模型")
                        .foregroundStyle(.secondary)
                }

                ForEach(installedModels) { model in
                    InstalledModelRow(
                        model: model,
                        onDelete: {
                            modelPendingDeletion = model
                            showingDeleteConfirmation = true
                        }
                    )
                }
            } label: {
                HStack {
                    Text(installedTitle)
                    Spacer()
                }
            }
        }
    }

    private var installedTitle: String {
        installedModels.isEmpty ? "已安装" : "已安装 \(installedModels.count) 个"
    }

    private var categorySelectorSection: some View {
        Section("模型分类") {
            CategoryTabBar(categories: availableCategories, selection: $selectedCategory)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowBackground(Color.clear)
                .onAppear {
                    if availableCategories.contains(selectedCategory) == false,
                       let firstCategory = availableCategories.first {
                        selectedCategory = firstCategory
                    }
                }
        }
    }

    private var selectedCatalogSection: some View {
        let categoryModels = downloadableModels.filter { $0.metadata.category == selectedCategory }
        let categoryOrganizations = organizations(in: categoryModels)

        return Section {
            if categoryModels.isEmpty {
                Text("该类别暂无模型")
                    .foregroundStyle(.secondary)
            } else if categoryOrganizations.count == 1, let organization = categoryOrganizations.first {
                let organizationModels = models(for: organization, in: categoryModels)

                OrganizationHeader(
                    organization: organization,
                    modelCount: organizationModels.count
                )
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)

                ForEach(Array(organizationModels.enumerated()), id: \.element.id) { _, model in
                    DownloadModelRow(
                        model: model,
                        pairedModel: modelStore.pairedMMProj(for: model),
                        isInstalled: modelStore.isInstalledForDisplay(model),
                        isPartiallyInstalled: modelStore.isPartiallyInstalled(model),
                        downloadState: modelStore.downloadState[model.id],
                        pairedDownloadState: pairedDownloadState(for: model),
                        onDownload: { modelStore.download(model) },
                        onRemovePartialDownload: {
                            partialDownloadPendingDeletion = model
                            showingPartialDeleteConfirmation = true
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(Array(categoryOrganizations.enumerated()), id: \.element.id) { organizationIndex, organization in
                    let organizationModels = models(for: organization, in: categoryModels)

                    DisclosureGroup(
                        isExpanded: bindingForOrganization(organization, in: selectedCategory),
                        content: {
                            ForEach(Array(organizationModels.enumerated()), id: \.element.id) { _, model in
                                DownloadModelRow(
                                    model: model,
                                    pairedModel: modelStore.pairedMMProj(for: model),
                                    isInstalled: modelStore.isInstalledForDisplay(model),
                                    isPartiallyInstalled: modelStore.isPartiallyInstalled(model),
                                    downloadState: modelStore.downloadState[model.id],
                                    pairedDownloadState: pairedDownloadState(for: model),
                                    onDownload: { modelStore.download(model) },
                                    onRemovePartialDownload: {
                                        partialDownloadPendingDeletion = model
                                        showingPartialDeleteConfirmation = true
                                    }
                                )
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparator(.hidden)
                            }
                        },
                        label: {
                            OrganizationHeader(
                                organization: organization,
                                modelCount: organizationModels.count,
                                showsTopDivider: organizationIndex > 0
                            )
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    private func models(for organization: ModelDescriptor.Organization, in models: [ModelDescriptor]) -> [ModelDescriptor] {
        models.filter { $0.metadata.organization == organization }
    }

    private func organizations(in models: [ModelDescriptor]) -> [ModelDescriptor.Organization] {
        ModelDescriptor.Organization.allCases.filter { organization in
            models.contains { $0.metadata.organization == organization }
        }
    }

    private var availableCategories: [ModelDescriptor.Category] {
        ModelDescriptor.Category.allCases.filter { category in
            downloadableModels.contains { $0.metadata.category == category }
        }
    }

    private func bindingForOrganization(_ organization: ModelDescriptor.Organization, in category: ModelDescriptor.Category) -> Binding<Bool> {
        let key = "\(category.rawValue).\(organization.rawValue)"
        return Binding(
            get: { expandedOrganizationKeys.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedOrganizationKeys.insert(key)
                } else {
                    expandedOrganizationKeys.remove(key)
                }
            }
        )
    }

    private func pairedDownloadState(for model: ModelDescriptor) -> ModelStore.DownloadState? {
        guard let pairedID = model.pairedMMProjID else { return nil }
        return modelStore.downloadState[pairedID]
    }

    private var deleteButtonTitle: String {
        if let model = modelPendingDeletion {
            return "删除 \(model.name)"
        }
        return "删除"
    }

    private var deleteMessage: String {
        if let model = modelPendingDeletion {
            return "这会从本机删除 \(model.name) 并释放存储空间，之后可以重新下载。"
        }
        return "这会从本机删除已下载模型并释放存储空间。"
    }

    private var partialDeleteButtonTitle: String {
        if let model = partialDownloadPendingDeletion {
            return "移除 \(model.name)"
        }
        return "移除"
    }
}

private struct OrganizationHeader: View {
    let organization: ModelDescriptor.Organization
    let modelCount: Int
    var showsTopDivider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTopDivider {
                Divider()
                    .padding(.bottom, 12)
            }

            HStack(spacing: 10) {
                RemoteAvatar(organization: organization, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(organization.displayName)
                        .font(.headline)
                    Text("\(modelCount) 个模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CategoryTabBar: View {
    let categories: [ModelDescriptor.Category]
    @Binding var selection: ModelDescriptor.Category

    var body: some View {
        HStack(spacing: 8) {
            ForEach(categories, id: \.self) { category in
                Button {
                    selection = category
                } label: {
                    Text(category.rawValue)
                        .font(.subheadline.weight(selection == category ? .semibold : .regular))
                        .foregroundStyle(selection == category ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection == category ? Color.accentColor : Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RemoteAvatar: View {
    let organization: ModelDescriptor.Organization
    let size: CGFloat

    var body: some View {
        Group {
            if let logoAssetName = organization.logoAssetName {
                Image(logoAssetName)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.quaternary)
            Image(systemName: organization.fallbackSymbol)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct InstalledModelRow: View {
    let model: ModelDescriptor
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteAvatar(organization: model.metadata.organization, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                    .font(.headline)
                ModelMetadataLine(model: model)
            }
            Spacer()
            if model.kind == .privacyFilter {
                Text("可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private struct DownloadModelRow: View {
    let model: ModelDescriptor
    let pairedModel: ModelDescriptor?
    let isInstalled: Bool
    let isPartiallyInstalled: Bool
    let downloadState: ModelStore.DownloadState?
    let pairedDownloadState: ModelStore.DownloadState?
    var showsTopDivider = true
    let onDownload: () -> Void
    let onRemovePartialDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTopDivider {
                Divider()
                    .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.name)
                            .font(.headline)
                        ModelMetadataLine(model: model)
                    }
                    Spacer()
                    actionButton
                }

                if isDownloading(downloadState) || isDownloading(pairedDownloadState) {
                    DownloadPartRow(
                        title: mainPartTitle,
                        state: downloadState
                    )

                    if pairedModel != nil {
                        DownloadPartRow(
                            title: "视觉组件",
                            state: pairedDownloadState
                        )
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInstalled {
            Label("已下载", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if isDownloading(downloadState) || isDownloading(pairedDownloadState) {
            Text("下载中")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if hasFailed(downloadState) || hasFailed(pairedDownloadState) {
            Button("重试", action: onDownload)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                Button(isPartiallyInstalled ? "继续" : "下载", action: onDownload)
                if isPartiallyInstalled {
                    Button("移除", role: .destructive, action: onRemovePartialDownload)
                        .font(.caption)
                }
            }
        }
    }

    private var mainPartTitle: String {
        model.kind == .privacyFilter ? "隐私过滤文件" : "模型文件"
    }

    private func isDownloading(_ state: ModelStore.DownloadState?) -> Bool {
        if case .downloading = state?.status {
            return true
        }
        return false
    }

    private func hasFailed(_ state: ModelStore.DownloadState?) -> Bool {
        if case .failed = state?.status {
            return true
        }
        return false
    }

}

private struct ModelMetadataLine: View {
    let model: ModelDescriptor

    var body: some View {
        Text("大小 \(normalizedSize) · 参数 \(model.metadata.parameterCount) · 发布时间 \(model.metadata.releaseMonth)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var normalizedSize: String {
        model.metadata.modelSize
            .replacingOccurrences(of: "约 ", with: "")
            .replacingOccurrences(of: " GB", with: "GB")
            .replacingOccurrences(of: " MB", with: "MB")
    }
}

private struct DownloadPartRow: View {
    let title: String
    let state: ModelStore.DownloadState?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                statusView
            }

            if case .downloading = state?.status {
                ProgressView(value: state?.progress ?? 0)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var statusView: some View {
        if let state {
            switch state.status {
            case .downloading:
                Text("\(Int((state.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .downloaded:
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .idle:
                Text("未下载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("等待中")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
