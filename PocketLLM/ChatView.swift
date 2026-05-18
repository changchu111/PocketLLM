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
    @State private var showingModelSettings = false

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

                if let error = viewModel.errorMessage {
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

            if showingModelSettings {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showingModelSettings = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(2)

                ModelSettingsSheet(viewModel: viewModel) {
                    showingModelSettings = false
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(3)
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
                        withAnimation(.easeOut(duration: 0.16)) {
                            showingModelSettings = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }

                    Button {
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
}

private struct ChatModelSelector: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Menu {
            if viewModel.installedModels.isEmpty {
                Text("没有已安装模型")
            } else {
                ForEach(viewModel.installedModels) { model in
                    Button {
                        viewModel.selectModel(model)
                    } label: {
                        Label(model.name.quantizationDisplayName, systemImage: model.id == viewModel.activeModelID ? "checkmark" : "circle")
                    }
                }
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
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    @State private var imageSlices: Double
    @State private var useGPU: Bool
    @State private var thinkingEnabled: Bool

    init(viewModel: ChatViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        _maxTokens = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaMaxNewTokens : viewModel.maxNewTokens))
        _contextLength = State(initialValue: Double(viewModel.contextLength))
        _topK = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaTopK : viewModel.topK))
        _topP = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaTopP : viewModel.topP))
        _temperature = State(initialValue: Double(viewModel.activeModelIsGemma4 ? viewModel.gemmaTemperature : viewModel.temperature))
        _repeatPenalty = State(initialValue: Double(viewModel.repeatPenalty))
        _presencePenalty = State(initialValue: Double(viewModel.presencePenalty))
        _frequencyPenalty = State(initialValue: Double(viewModel.frequencyPenalty))
        _imageSlices = State(initialValue: Double(viewModel.miniCPMV46ImageSlices))
        _useGPU = State(initialValue: viewModel.gemmaUseGPU)
        _thinkingEnabled = State(initialValue: viewModel.gemmaThinkingEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型配置")
                .font(.title2.weight(.semibold))

            Text(viewModel.activeModelName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            ConfigSliderRow(title: "最大 Token 数", value: $maxTokens, range: viewModel.activeModelIsGemma4 ? 16...32000 : 16...4096, integerOnly: true)

            if viewModel.activeModelIsMiniCPMV46 {
                ConfigSliderRow(title: "图片切片数", value: $imageSlices, range: 1...9, integerOnly: true)
                ConfigInfoText("MiniCPM-V 4.6 使用推荐采样：Temperature 0.7、TopP 0.8、TopK 100、Repeat Penalty 1.05。切片越多越利于识别细节，但会增加耗时。")
            } else if viewModel.activeModelIsGemma4 {
                ConfigSliderRow(title: "TopK", value: $topK, range: 0...64, integerOnly: true)
                ConfigSliderRow(title: "TopP", value: $topP, range: 0...1, integerOnly: false)
                ConfigSliderRow(title: "Temperature", value: $temperature, range: 0...2, integerOnly: false)

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

                Toggle("启用思考", isOn: $thinkingEnabled)
                    .font(.subheadline.weight(.semibold))
                    .tint(.accentColor)
            } else {
                ConfigSliderRow(title: "上下文长度", value: $contextLength, range: 512...16384, integerOnly: true)
                ConfigSliderRow(title: "TopK", value: $topK, range: 0...200, integerOnly: true)
                ConfigSliderRow(title: "TopP", value: $topP, range: 0...1, integerOnly: false)
                ConfigSliderRow(title: "Temperature", value: $temperature, range: 0...1.5, integerOnly: false)
                ConfigSliderRow(title: "Repeat Penalty", value: $repeatPenalty, range: 0.8...2, integerOnly: false)

                if viewModel.activeModelIsVLM {
                    ConfigInfoText("当前 VLM 的视觉分辨率、图片批处理等参数由运行时按模型自动选择。")
                } else {
                    ConfigSliderRow(title: "Presence Penalty", value: $presencePenalty, range: 0...2, integerOnly: false)
                    ConfigSliderRow(title: "Frequency Penalty", value: $frequencyPenalty, range: 0...2, integerOnly: false)
                }
            }

            HStack {
                Text("随机种子")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(viewModel.seed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("随机") {
                    viewModel.randomizeSeed()
                }
                .font(.caption.weight(.semibold))
            }

            HStack(spacing: 14) {
                Spacer()
                Button("取消") {
                    withAnimation(.easeOut(duration: 0.16)) { onDismiss() }
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    applySettings()
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
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: 320)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 24)
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
            viewModel.miniCPMV46ImageSlices = Int32(Self.clamp(imageSlices, in: 1...9).rounded())
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

    private static func clamp(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
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
    @Binding var value: Double
    let range: ClosedRange<Double>
    let integerOnly: Bool

    @State private var draftValue = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))

            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .tint(.accentColor)
                    .onChange(of: value) { _, newValue in
                        guard isEditing == false else { return }
                        draftValue = formatted(newValue)
                    }

                TextField("", text: $draftValue)
                    .font(.subheadline.monospacedDigit())
                    .keyboardType(integerOnly ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.leading)
                    .focused($isEditing)
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

        let clampedValue = min(max(parsedValue, range.lowerBound), range.upperBound)
        value = clampedValue
        draftValue = formatted(clampedValue)
    }

    private func formatted(_ number: Double) -> String {
        if integerOnly {
            return "\(Int(number.rounded()))"
        }
        return String(format: "%.2f", number)
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

    var body: some View {
        ForEach(attachments) { attachment in
            if let image = UIImage(contentsOfFile: attachment.localPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
