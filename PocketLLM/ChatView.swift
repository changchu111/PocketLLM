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
                        onCamera: {
                            isComposerFocused = false
                            showingCamera = true
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

            if viewModel.isSwitchingModel {
                ChatLoadingOverlay(message: viewModel.modelLoadingMessage)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.prepareForChat()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        showingModelSettings = true
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
        .sheet(isPresented: $showingModelSettings) {
            ModelSettingsSheet(viewModel: viewModel)
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
                        Label(model.name, systemImage: model.name == viewModel.activeModelName ? "checkmark" : "circle")
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("当前模型") {
                    Text(viewModel.activeModelName)
                }

                if viewModel.activeModelIsMiniCPMV46 {
                    Section("MiniCPM-V 4.6") {
                        HStack {
                            Text("图片切片数")
                            Spacer()
                            Text("\(viewModel.miniCPMV46ImageSlices)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Stepper(value: Binding(get: {
                            Int(viewModel.miniCPMV46ImageSlices)
                        }, set: { newValue in
                            viewModel.miniCPMV46ImageSlices = Int32(newValue)
                        }), in: 1...9) {
                            Text("调整")
                        }
                        Text("切片越多越利于识别细节，但会增加图片编码和推理耗时。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("配置项") {
                        Text("当前模型没有配置项")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("模型设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ChatLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(message)
                    .font(.headline)
                Text("Please wait until the model is ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 10)
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
            switch attachment.type {
            case .image:
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
    let onCamera: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCamera) {
                Image(systemName: "camera")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

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
