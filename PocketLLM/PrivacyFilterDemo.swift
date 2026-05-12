import SwiftUI
import Combine

@MainActor
final class PrivacyFilterDemoViewModel: ObservableObject {
    @Published var draft: String = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var lastResult: PrivacyFilterResult?
    @Published private(set) var isProcessing = false
    @Published private(set) var statusText = "首次使用会下载并加载 OpenAI Privacy Filter ONNX 模型。"

    private let model = OpenAIPrivacyFilterModel()
    private var task: Task<Void, Never>?

    func send(text: String? = nil) {
        let text = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isProcessing == false else { return }

        draft = ""
        isProcessing = true
        statusText = "正在运行 OpenAI Privacy Filter..."

        task = Task { [model] in
            do {
                let result = try await model.sanitize(text: text) { state in
                    await MainActor.run {
                        self.statusText = Self.statusText(for: state)
                    }
                }

                guard Task.isCancelled == false else { return }

                self.lastResult = result
                self.messages.append(ChatMessage(role: .user, text: result.originalText))
                self.messages.append(ChatMessage(role: .assistant, text: result.sanitizedText))
                self.statusText = result.summary ?? "模型未检测到需要脱敏的个人身份信息。"
            } catch {
                guard Task.isCancelled == false else { return }
                self.statusText = "OpenAI Privacy Filter 运行失败：\(error.localizedDescription)"
            }

            guard Task.isCancelled == false else { return }
            self.isProcessing = false
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        draft = ""
        messages = []
        lastResult = nil
        isProcessing = false
        statusText = "首次使用会下载并加载 OpenAI Privacy Filter ONNX 模型。"
    }

    private static func statusText(for state: OpenAIPrivacyFilterModel.ModelState) -> String {
        switch state {
        case .idle:
            return "准备加载 OpenAI Privacy Filter。"
        case .downloading(let progress, let filename):
            return "正在下载 OpenAI Privacy Filter 模型文件… \(Int(progress * 100))% · \(filename)"
        case .loading:
            return "正在加载 tokenizer 和 ONNX 模型…"
        case .ready:
            return "OpenAI Privacy Filter 已就绪，正在检测和脱敏。"
        case .failed(let message):
            return "OpenAI Privacy Filter 运行失败：\(message)"
        }
    }
}

struct PrivacyFilterDemoView: View {
    @StateObject private var viewModel = PrivacyFilterDemoViewModel()
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PrivacyFilterIntroCard()
                .padding(.horizontal)
                .padding(.top, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            PrivacyFilterMessageRow(message: message)
                                .id(message.id)
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

            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 6)

            PrivacyFilterComposerBar(
                text: $viewModel.draft,
                isProcessing: viewModel.isProcessing,
                onSend: { text in
                    viewModel.send(text: text)
                },
                isFocused: $isComposerFocused
            )
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("隐私过滤")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "eraser")
                }
            }
        }
    }

}

private struct PrivacyFilterIntroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("体验OpenAI Privacy Filter模型，对个人身份信息检测和脱敏")
                .font(.headline)
            Text("输入包含邮箱、电话、链接等信息的内容，查看原文与脱敏结果对比。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PrivacyFilterMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "原始 Query" : "脱敏后 Query")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Text(message.text)
                    .textSelection(.enabled)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .overlay {
                        if message.role != .user {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
                        }
                    }
            }

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground)
    }
}

private struct PrivacyFilterComposerBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let onSend: (String) -> Void
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("输入需要检测和脱敏的内容", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            if isProcessing {
                ProgressView()
                    .frame(width: 40, height: 40)
            } else {
                Button(action: submit) {
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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isProcessing == false
    }

    private func submit() {
        let submittedText = text
        text = ""
        isFocused = false
        onSend(submittedText)
    }
}
