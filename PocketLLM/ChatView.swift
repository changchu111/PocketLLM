import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatSurface(viewModel: viewModel, title: "PocketLLM")
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let title: String
    var introTitle: String?
    var introText: String?
    var requiresImage: Bool = false

    var body: some View {
        ChatSurface(
            viewModel: viewModel,
            title: title,
            introTitle: introTitle,
            introText: introText,
            requiresImage: requiresImage
        )
    }
}

private struct ChatSurface: View {
    @ObservedObject var viewModel: ChatViewModel
    let title: String
    var introTitle: String? = nil
    var introText: String? = nil
    var requiresImage: Bool = false

    @FocusState private var isComposerFocused: Bool
    @State private var showingCamera = false

    private var visibleMessages: [ChatMessage] {
        viewModel.messages.filter { $0.role != .system }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ChatModelSelector(viewModel: viewModel)
                    .padding(.horizontal)
                    .padding(.top, 10)

                if introTitle != nil || introText != nil || requiresImage {
                    DemoIntroCard(title: introTitle, text: introText, requiresImage: requiresImage)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleMessages) { msg in
                                MessageRow(message: msg, isStreaming: msg.id == viewModel.streamingAssistantID)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isComposerFocused = false
                    }
                    .onChange(of: viewModel.messages.last?.id) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(newID, anchor: .bottom)
                        }
                    }
                }

                if viewModel.modelLoadFailed {
                    HStack(spacing: 10) {
                        Text("模型加载失败")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)

                        Button("重试") {
                            viewModel.retryModelLoad()
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                } else if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }

                VStack(spacing: 8) {
                    #if canImport(UIKit)
                    if let image = viewModel.pendingImage {
                        AttachmentChip(image: image) {
                            viewModel.clearPendingImage()
                        }
                        .padding(.horizontal)
                    }
                    #endif

                    ComposerBar(
                        text: $viewModel.draft,
                        hasAttachment: viewModel.pendingImage != nil,
                        isGenerating: viewModel.isGenerating,
                        supportsImageInput: viewModel.activeModelIsVLM,
                        onCamera: {
                            isComposerFocused = false
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                showingCamera = true
                            }
                        },
                        onSend: { viewModel.send() },
                        onStop: { viewModel.stop() },
                        isFocused: $isComposerFocused
                    )
                    .padding(.horizontal)
                }
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.prepareForChat()
        }
        .onDisappear {
            viewModel.leaveChat(clearSession: showingCamera == false)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        dismissKeyboard()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            withAnimation(.easeOut(duration: 0.16)) {
                                viewModel.showingModelSettings = true
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }

                    Button {
                        dismissKeyboard()
                        viewModel.clearChat()
                    } label: {
                        Image(systemName: "eraser")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraScreen(
                onClose: { showingCamera = false },
                onImage: { image in
                    viewModel.setPendingImage(image)
                    showingCamera = false
                }
            )
        }
    }

    private func dismissKeyboard() {
        isComposerFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

struct ModelSettingsOverlay: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissKeyboard()
                    withAnimation(.easeOut(duration: 0.16)) {
                        isPresented = false
                    }
                }

            ModelSettingsSheet(viewModel: viewModel) {
                isPresented = false
            }
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .transition(.opacity)
        .zIndex(100)
        .allowsHitTesting(true)
        .accessibilityAddTraits(.isModal)
    }
}

private func dismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

private struct ChatModelSelector: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var viewModel: ChatViewModel
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    showingPicker.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前模型")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(viewModel.activeModelName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showingPicker ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if showingPicker {
                ChatModelPicker(
                    viewModel: viewModel,
                    onSelect: { model in
                        viewModel.selectModel(model)
                        withAnimation(.easeOut(duration: 0.16)) {
                            showingPicker = false
                        }
                    },
                    onMoreModels: {
                        showingPicker = false
                        appModel.selectedTab = .models
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ChatModelPicker: View {
    @ObservedObject var viewModel: ChatViewModel
    let onSelect: (ModelDescriptor) -> Void
    let onMoreModels: () -> Void

    private var llmModels: [ModelDescriptor] {
        viewModel.installedModels.filter { $0.metadata.category == .llm }
    }

    private var vlmModels: [ModelDescriptor] {
        viewModel.installedModels.filter { $0.metadata.category == .vlm }
    }

    private var maxPickerHeight: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.height * 0.6
        #else
        560
        #endif
    }

    private var estimatedListHeight: CGFloat {
        let modelRows = CGFloat(viewModel.installedModels.isEmpty ? 1 : viewModel.installedModels.count) * 78
        let sectionHeaders = CGFloat((llmModels.isEmpty ? 0 : 1) + (vlmModels.isEmpty ? 0 : 1)) * 34
        let groupDivider: CGFloat = llmModels.isEmpty == false && vlmModels.isEmpty == false ? 10 : 0
        return modelRows + sectionHeaders + groupDivider + 12
    }

    private var footerHeight: CGFloat { 54 }

    private var listHeight: CGFloat {
        min(estimatedListHeight, maxPickerHeight - footerHeight)
    }

    private var shouldScroll: Bool {
        estimatedListHeight > maxPickerHeight - footerHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                modelListContent
            }
            .scrollDisabled(shouldScroll == false)
            .frame(height: listHeight)

            Divider()
            moreModelsButton
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var modelListContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.installedModels.isEmpty {
                Text("没有已安装模型")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                if llmModels.isEmpty == false {
                    ChatModelPickerSection(
                        title: "LLM",
                        models: llmModels,
                        activeModelID: viewModel.activeModelID,
                        onSelect: onSelect
                    )
                }

                if llmModels.isEmpty == false && vlmModels.isEmpty == false {
                    CatalogDivider(horizontalInset: 16)
                        .padding(.vertical, 4)
                }

                if vlmModels.isEmpty == false {
                    ChatModelPickerSection(
                        title: "VLM",
                        models: vlmModels,
                        activeModelID: viewModel.activeModelID,
                        onSelect: onSelect
                    )
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var moreModelsButton: some View {
        Button(action: onMoreModels) {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
                Text("查看更多模型")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }
}

private struct ChatModelPickerSection: View {
    let title: String
    let models: [ModelDescriptor]
    let activeModelID: String?
    let onSelect: (ModelDescriptor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 {
                    CatalogDivider(horizontalInset: 62)
                }

                ChatModelPickerRow(
                    model: model,
                    isSelected: model.id == activeModelID,
                    onSelect: { onSelect(model) }
                )
            }
        }
    }
}

private struct ChatModelPickerRow: View {
    let model: ModelDescriptor
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                RemoteAvatar(organization: model.metadata.organization, size: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.name.quantizationDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    ModelMetadataLine(model: model)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ModelSettingsSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    let onDismiss: () -> Void

    @State private var maxTokens: Double
    @State private var contextLength: Double
    @State private var topK: Double
    @State private var topP: Double
    @State private var temperature: Double
    @State private var repeatPenalty: Double
    @State private var presencePenalty: Double
    @State private var frequencyPenalty: Double
    @State private var useGPU: Bool
    @State private var thinkingEnabled: Bool
    @State private var showingAdvanced = false
    @State private var advancedImageMaxDimension: Double
    @State private var advancedUseOriginalImage: Bool
    @State private var advancedImageMaxSlices: Double
    @State private var advancedBatchSize: Double
    @State private var advancedUbatchSize: Double
    @State private var advancedImageEvalBatchSize: Double
    @State private var advancedForceMMProjCPU: Bool
    @State private var helpText: ConfigHelpText?

    private var imageResolutionRange: ClosedRange<Double> {
        viewModel.activeModelIsQwen35VLM ? 448...1680 : 768...1680
    }

    private var supportsOriginalImageMode: Bool {
        viewModel.activeModelIsQwen35VLM == false
    }

    init(viewModel: ChatViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        _maxTokens = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaMaxNewTokens : (viewModel.activeModelIsMiniCPMV46 ? viewModel.miniCPMV46MaxNewTokens : viewModel.maxNewTokens)))
        _contextLength = State(initialValue: Double(viewModel.contextLength))
        _topK = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaTopK : (viewModel.activeModelIsMiniCPMV46 ? viewModel.miniCPMV46TopK : viewModel.topK)))
        _topP = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaTopP : (viewModel.activeModelIsMiniCPMV46 ? viewModel.miniCPMV46TopP : viewModel.topP)))
        _temperature = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaTemperature : (viewModel.activeModelIsMiniCPMV46 ? viewModel.miniCPMV46Temperature : viewModel.temperature)))
        _repeatPenalty = State(initialValue: Double(viewModel.activeModelIsMiniCPMV46 ? viewModel.miniCPMV46RepeatPenalty : viewModel.repeatPenalty))
        _presencePenalty = State(initialValue: Double(viewModel.presencePenalty))
        _frequencyPenalty = State(initialValue: Double(viewModel.frequencyPenalty))
        _useGPU = State(initialValue: viewModel.gemmaUseGPU)
        _thinkingEnabled = State(initialValue: viewModel.gemmaThinkingEnabled)
        let advanced = viewModel.activeVLMRuntimeSettings
        _advancedImageMaxDimension = State(initialValue: Double(advanced.imageMaxDimension))
        _advancedUseOriginalImage = State(initialValue: advanced.useOriginalImage)
        _advancedImageMaxSlices = State(initialValue: Double(advanced.imageMaxSlices))
        _advancedBatchSize = State(initialValue: Double(advanced.batchSize))
        _advancedUbatchSize = State(initialValue: Double(advanced.ubatchSize))
        _advancedImageEvalBatchSize = State(initialValue: Double(advanced.imageEvalBatchSize))
        _advancedForceMMProjCPU = State(initialValue: advanced.forceMMProjCPU)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingAdvanced {
                advancedContent
            } else {
                mainContent
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: 320)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    private var mainContent: some View {
        Group {
            Text("模型配置")
                .font(.title2.weight(.semibold))

            Text(viewModel.activeModelName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            ConfigSliderRow(title: "最大 Token 数", value: $maxTokens, range: viewModel.activeModelIsGemma4 ? 16...32000 : 16...4096, integerOnly: true)

            if viewModel.activeModelIsMiniCPMV46 {
                ConfigSliderRow(title: "TopK", value: $topK, range: 0...200, integerOnly: true)
                ConfigSliderRow(title: "TopP", value: $topP, range: 0...1, integerOnly: false)
                ConfigSliderRow(title: "Temperature", value: $temperature, range: 0...1.5, integerOnly: false)
                ConfigSliderRow(title: "Repeat Penalty", value: $repeatPenalty, range: 0.8...2, integerOnly: false)
            } else if viewModel.activeModelIsGemma4 {
                ConfigSliderRow(title: "TopK", value: $topK, range: 0...64, integerOnly: true)
                ConfigSliderRow(title: "TopP", value: $topP, range: 0...1, integerOnly: false)
                ConfigSliderRow(title: "Temperature", value: $temperature, range: 0...2, integerOnly: false)
                acceleratorPicker
                Toggle("启用思考", isOn: $thinkingEnabled)
                    .font(.subheadline.weight(.semibold))
                    .tint(.accentColor)
            } else {
                ConfigSliderRow(title: "上下文长度", value: $contextLength, range: 512...16384, integerOnly: true)
                ConfigSliderRow(title: "TopK", value: $topK, range: 0...200, integerOnly: true)
                ConfigSliderRow(title: "TopP", value: $topP, range: 0...1, integerOnly: false)
                ConfigSliderRow(title: "Temperature", value: $temperature, range: 0...1.5, integerOnly: false)
                ConfigSliderRow(title: "Repeat Penalty", value: $repeatPenalty, range: 0.8...2, integerOnly: false)

                if viewModel.activeModelIsVLM == false {
                    ConfigSliderRow(title: "Presence Penalty", value: $presencePenalty, range: 0...2, integerOnly: false)
                    ConfigSliderRow(title: "Frequency Penalty", value: $frequencyPenalty, range: 0...2, integerOnly: false)
                }
            }

            HStack(spacing: 14) {
                if viewModel.activeModelIsVLM {
                    Button("高级") {
                        withAnimation(.easeOut(duration: 0.16)) { showingAdvanced = true }
                    }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()
                Button("取消") {
                    withAnimation(.easeOut(duration: 0.16)) { onDismiss() }
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    applySettings()
                    applyAdvancedSettings()
                    withAnimation(.easeOut(duration: 0.16)) { onDismiss() }
                } label: {
                    Text("确定")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 40)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    private var advancedContent: some View {
        Group {
            Text("高级配置")
                .font(.title2.weight(.semibold))

            ConfigSliderRow(
                title: "视觉分辨率",
                help: ConfigHelpText(title: "视觉分辨率", message: "控制 app 侧送入视觉模型前的整图最长边尺寸。数值越大，图片细节越多，但处理更慢、更吃内存。"),
                value: $advancedImageMaxDimension,
                range: imageResolutionRange,
                step: 16,
                integerOnly: true,
                isEnabled: advancedUseOriginalImage == false || supportsOriginalImageMode == false,
                onHelp: showHelp
            )

            if supportsOriginalImageMode {
                ConfigToggleRow(
                    title: "原图",
                    help: ConfigHelpText(title: "原图", message: "勾选后不在 app 侧预先缩小图片，尽量把原图交给多模态处理器处理。效果可能更好，但会明显变慢并增加内存风险。"),
                    isOn: $advancedUseOriginalImage,
                    onHelp: showHelp
                )
                .onChange(of: advancedUseOriginalImage) { _, useOriginal in
                    if useOriginal {
                        dismissKeyboard()
                    } else {
                        advancedImageMaxDimension = Self.quantizedImageDimension(advancedImageMaxDimension, in: imageResolutionRange)
                    }
                }
            }

            if viewModel.activeModelIsMiniCPMV46 {
                ConfigSliderRow(
                    title: "图片切片数",
                    help: ConfigHelpText(title: "图片切片数", message: "允许模型把大图切成多个局部区域细看。对 OCR、截图、表格更有帮助；数值越大越慢、越占内存。"),
                    value: $advancedImageMaxSlices,
                    range: 1...9,
                    integerOnly: true,
                    onHelp: showHelp
                )
            }
            ConfigSliderRow(
                title: "Batch Size",
                help: ConfigHelpText(title: "Batch Size", message: "提示词处理阶段一次组织处理的 token 数。调高可能更快，但更容易触发内存或 Metal 问题。"),
                value: $advancedBatchSize,
                range: 256...1024,
                integerOnly: true,
                onHelp: showHelp
            )
            ConfigSliderRow(
                title: "UBatch Size",
                help: ConfigHelpText(title: "UBatch Size", message: "底层实际每小批执行的 token 数。比 Batch 更直接影响单次计算压力；调低通常更稳但更慢。"),
                value: $advancedUbatchSize,
                range: 256...1024,
                integerOnly: true,
                onHelp: showHelp
            )
            ConfigSliderRow(
                title: "图片 Batch",
                help: ConfigHelpText(title: "图片 Batch", message: "看图阶段处理视觉 token 的批量。调高看图更快，但 GPU/内存压力更大。"),
                value: $advancedImageEvalBatchSize,
                range: 128...1024,
                integerOnly: true,
                onHelp: showHelp
            )

            ConfigToggleRow(
                title: "视觉投影使用 CPU",
                help: ConfigHelpText(title: "视觉投影使用 CPU", message: "控制 mmproj/视觉投影器跑 CPU 还是 GPU。CPU 更稳但慢；GPU 更快但更吃 Metal/显存。"),
                isOn: $advancedForceMMProjCPU,
                onHelp: showHelp
            )

            HStack(spacing: 14) {
                Button("返回") {
                    withAnimation(.easeOut(duration: 0.16)) { showingAdvanced = false }
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("取消") {
                    withAnimation(.easeOut(duration: 0.16)) { onDismiss() }
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    applySettings()
                    applyAdvancedSettings()
                    withAnimation(.easeOut(duration: 0.16)) { onDismiss() }
                } label: {
                    Text("确定")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 40)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
        .alert(item: $helpText) { help in
            Alert(title: Text(help.title), message: Text(help.message), dismissButton: .default(Text("知道了")))
        }
    }

    private var acceleratorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择加速方式")
                .font(.caption.weight(.semibold))

            HStack(spacing: 6) {
                AcceleratorSegmentButton(title: "CPU", isSelected: useGPU == false) { setUseGPU(false) }
                AcceleratorSegmentButton(title: "GPU", isSelected: useGPU) { setUseGPU(true) }
            }
            .padding(3)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func setUseGPU(_ enabled: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { useGPU = enabled }
    }

    private func applySettings() {
        if viewModel.activeModelIsGemma4 {
            viewModel.applyGemmaSettings(
                maxNewTokens: Int32(Self.clamp(maxTokens, in: 16...32000).rounded()),
                temperature: Float(Self.clamp(temperature, in: 0...2)),
                topK: Int32(Self.clamp(topK, in: 0...64).rounded()),
                topP: Float(Self.clamp(topP, in: 0...1)),
                useGPU: useGPU,
                thinkingEnabled: thinkingEnabled
            )
            return
        }

        viewModel.maxNewTokens = Int32(Self.clamp(maxTokens, in: 16...4096).rounded())
        if viewModel.activeModelIsMiniCPMV46 {
            viewModel.applyMiniCPMV46Settings(
                maxNewTokens: Int32(Self.clamp(maxTokens, in: 16...4096).rounded()),
                temperature: Float(Self.clamp(temperature, in: 0...1.5)),
                topK: Int32(Self.clamp(topK, in: 0...200).rounded()),
                topP: Float(Self.clamp(topP, in: 0...1)),
                repeatPenalty: Float(Self.clamp(repeatPenalty, in: 0.8...2)),
                imageSlices: viewModel.miniCPMV46ImageSlices
            )
            return
        }

        viewModel.contextLength = Int32(Self.clamp(contextLength, in: 512...16384).rounded())
        viewModel.temperature = Float(Self.clamp(temperature, in: 0...1.5))
        viewModel.topK = Int32(Self.clamp(topK, in: 0...200).rounded())
        viewModel.topP = Float(Self.clamp(topP, in: 0...1))
        viewModel.repeatPenalty = Float(Self.clamp(repeatPenalty, in: 0.8...2))
        viewModel.presencePenalty = Float(Self.clamp(presencePenalty, in: 0...2))
        viewModel.frequencyPenalty = Float(Self.clamp(frequencyPenalty, in: 0...2))
    }

    private func applyAdvancedSettings() {
        guard viewModel.activeModelIsVLM else { return }
        viewModel.applyActiveVLMRuntimeSettings(
            VLMRuntimeSettings(
                imageMaxDimension: Float(Self.quantizedImageDimension(advancedImageMaxDimension, in: imageResolutionRange)),
                useOriginalImage: supportsOriginalImageMode && advancedUseOriginalImage,
                imageMaxSlices: Int32(Self.clamp(advancedImageMaxSlices, in: 1...9).rounded()),
                batchSize: Int32(Self.clamp(advancedBatchSize, in: 256...1024).rounded()),
                ubatchSize: Int32(Self.clamp(advancedUbatchSize, in: 256...1024).rounded()),
                imageEvalBatchSize: Int32(Self.clamp(advancedImageEvalBatchSize, in: 128...1024).rounded()),
                forceMMProjCPU: advancedForceMMProjCPU
            )
        )
    }

    private static func clamp(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func quantizedImageDimension(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = clamp(value, in: range)
        return (clamped / 16).rounded() * 16
    }

    private func showHelp(_ help: ConfigHelpText) {
        dismissKeyboard()
        helpText = help
    }
}

private struct ConfigHelpText: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ConfigInfoText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GoogleGemmaConfigurationsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let onDismiss: () -> Void

    @State private var maxTokens: Double
    @State private var topK: Double
    @State private var topP: Double
    @State private var temperature: Double
    @State private var useGPU: Bool
    @State private var thinkingEnabled: Bool

    init(viewModel: ChatViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        _maxTokens = State(initialValue: Double(viewModel.gemmaMaxNewTokens))
        _topK = State(initialValue: Double(viewModel.gemmaTopK))
        _topP = State(initialValue: Double(viewModel.gemmaTopP))
        _temperature = State(initialValue: Double(viewModel.gemmaTemperature))
        _useGPU = State(initialValue: viewModel.gemmaUseGPU)
        _thinkingEnabled = State(initialValue: viewModel.gemmaThinkingEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                Text("模型配置")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 2)

                ConfigSliderRow(title: "最大 Token 数", value: $maxTokens, range: 16...32000, integerOnly: true)
                ConfigSliderRow(title: "TopK", value: $topK, range: 0...64, integerOnly: true)
                ConfigSliderRow(title: "TopP", value: $topP, range: 0...1, integerOnly: false)
                ConfigSliderRow(title: "Temperature", value: $temperature, range: 0...2, integerOnly: false)

                VStack(alignment: .leading, spacing: 8) {
                    Text("选择加速方式")
                        .font(.caption.weight(.semibold))

                    HStack(spacing: 6) {
                        AcceleratorSegmentButton(title: "CPU", isSelected: useGPU == false) {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                useGPU = false
                            }
                        }

                        AcceleratorSegmentButton(title: "GPU", isSelected: useGPU) {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                useGPU = true
                            }
                        }
                    }
                    .padding(3)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Toggle("启用思考", isOn: $thinkingEnabled)
                    .font(.subheadline.weight(.semibold))
                    .tint(.accentColor)

                HStack(spacing: 14) {
                    Spacer()
                    Button("取消") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            onDismiss()
                        }
                    }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Button {
                        viewModel.applyGemmaSettings(
                            maxNewTokens: Int32(Self.clamp(maxTokens, in: 16...32000).rounded()),
                            temperature: Float(Self.clamp(temperature, in: 0...2)),
                            topK: Int32(Self.clamp(topK, in: 0...64).rounded()),
                            topP: Float(Self.clamp(topP, in: 0...1)),
                            useGPU: useGPU,
                            thinkingEnabled: thinkingEnabled
                        )
                        withAnimation(.easeOut(duration: 0.16)) {
                            onDismiss()
                        }
                    } label: {
                        Text("确定")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 76, height: 40)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(maxWidth: 320)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 24)
    }

    private static func clamp(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct ConfigSliderRow: View {
    let title: String
    var help: ConfigHelpText? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let integerOnly: Bool
    var isEnabled: Bool = true
    var onHelp: ((ConfigHelpText) -> Void)? = nil

    @State private var draftValue = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConfigLabel(title: title, help: help, onHelp: onHelp)

            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .tint(.accentColor)
                    .disabled(isEnabled == false)
                    .onChange(of: value) { _, newValue in
                        guard isEditing == false else { return }
                        let adjustedValue = adjusted(newValue)
                        if adjustedValue != newValue {
                            value = adjustedValue
                        }
                        draftValue = formatted(adjustedValue)
                    }

                TextField("", text: $draftValue)
                    .font(.subheadline.monospacedDigit())
                    .keyboardType(integerOnly ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.leading)
                    .focused($isEditing)
                    .disabled(isEnabled == false)
                    .frame(width: 64, height: 30, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                    }
                    .onAppear {
                        draftValue = formatted(value)
                    }
                    .onSubmit {
                        commitDraftValue()
                    }
                    .onChange(of: draftValue) { _, newValue in
                        updateValueFromDraft(newValue)
                    }
                    .onChange(of: isEditing) { _, editing in
                        if editing == false {
                            commitDraftValue()
                        }
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
        }
    }

    private func updateValueFromDraft(_ draft: String) {
        guard let parsedValue = Double(draft) else { return }
        if parsedValue > range.upperBound {
            value = range.upperBound
            draftValue = formatted(range.upperBound)
            return
        }
        value = max(parsedValue, range.lowerBound)
    }

    private func commitDraftValue() {
        guard let parsedValue = Double(draftValue) else {
            draftValue = formatted(value)
            return
        }

        let clampedValue = adjusted(parsedValue)
        value = clampedValue
        draftValue = formatted(clampedValue)
    }

    private func adjusted(_ number: Double) -> Double {
        let clampedValue = min(max(number, range.lowerBound), range.upperBound)
        guard let step, step > 0 else { return clampedValue }
        let steppedValue = (clampedValue / step).rounded() * step
        return min(max(steppedValue, range.lowerBound), range.upperBound)
    }

    private func formatted(_ number: Double) -> String {
        if integerOnly {
            return "\(Int(number.rounded()))"
        }
        return String(format: "%.2f", number)
    }
}

private struct ConfigToggleRow: View {
    let title: String
    var help: ConfigHelpText? = nil
    @Binding var isOn: Bool
    var onHelp: ((ConfigHelpText) -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ConfigLabel(title: title, help: help, onHelp: onHelp)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.accentColor)
        }
    }
}

private struct ConfigLabel: View {
    let title: String
    var help: ConfigHelpText? = nil
    var onHelp: ((ConfigHelpText) -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if let help {
                Button {
                    onHelp?(help)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AcceleratorSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(isSelected ? Color(uiColor: .secondarySystemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}

private struct IntStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Stepper("调整", value: $value, in: range, step: step)
        }
    }
}

private struct FloatSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

struct ChatLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .zIndex(0)

            HStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 10)
            .zIndex(1)
        }
        .allowsHitTesting(true)
        .accessibilityAddTraits(.isModal)
    }
}

private struct DemoIntroCard: View {
    let title: String?
    let text: String?
    let requiresImage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if requiresImage {
                Label("请先添加一张图片，再发送消息体验这个 demo。", systemImage: "camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 6) {
                bubble
                if message.role == .assistant, let stats = message.stats {
                    MessageStatsView(stats: stats)
                        .padding(.horizontal, 4)
                }
            }

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.attachments.isEmpty {
                AttachmentsView(attachments: message.attachments)
            }
            if !message.text.isEmpty {
                MessageText(role: message.role, text: message.text, isStreaming: isStreaming)
            }
        }
        .padding(12)
        .background(message.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if message.role != .user {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
            }
        }
    }
}

private struct MessageStatsView: View {
    let stats: GenerationStats

    var body: some View {
        Text("TTFT \(formatSeconds(stats.ttftSeconds)) · \(formatTPS(stats.tokensPerSecond)) · 总计 \(formatSeconds(stats.totalSeconds))")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func formatSeconds(_ value: Double) -> String {
        if value >= 10 {
            return String(format: "%.1f s", value)
        }
        return String(format: "%.2f s", value)
    }

    private func formatTPS(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f token/s", value)
        }
        return String(format: "%.1f token/s", value)
    }
}

private struct AttachmentsView: View {
    let attachments: [ChatAttachment]
    @State private var previewImage: ImagePreviewItem?

    var body: some View {
        Group {
            ForEach(attachments) { attachment in
                if let image = UIImage(contentsOfFile: attachment.localPath) {
                    Button {
                        previewImage = ImagePreviewItem(image: image)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 240, maxHeight: 240)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看完整图片")
                }
            }
        }
        .fullScreenCover(item: $previewImage) { image in
            ImagePreviewScreen(image: image.image)
        }
    }
}

private struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ImagePreviewScreen: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            ZoomableImage(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        .statusBarHidden(true)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let zoomScale = min(scrollView.maximumZoomScale, 2.5)
                let width = scrollView.bounds.width / zoomScale
                let height = scrollView.bounds.height / zoomScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

private struct MessageText: View {
    let role: ChatRole
    let text: String
    let isStreaming: Bool

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AttachmentChip: View {
    let image: UIImage
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("图片")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text("已优化")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct ComposerBar: View {
    @Binding var text: String
    let hasAttachment: Bool
    let isGenerating: Bool
    let supportsImageInput: Bool
    let onCamera: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if supportsImageInput {
                Button(action: onCamera) {
                    Image(systemName: "camera")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            TextField("输入消息", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            if isGenerating {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Stop generating")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(canSend ? Color.accentColor : Color.gray)
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment
    }
}
