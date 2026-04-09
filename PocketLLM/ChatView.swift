import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var app: AppModel

    @FocusState private var isComposerFocused: Bool

    @State private var showingCamera = false

    private var visibleMessages: [ChatMessage] {
        viewModel.messages.filter { $0.role != .system }
    }


    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
            .navigationTitle("PocketLLM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }
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
            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
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
        // Markdown rendering disabled.
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

            Text("Photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text("optimized")
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

            TextField("Message", text: $text, axis: .vertical)
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
