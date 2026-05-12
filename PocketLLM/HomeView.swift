import SwiftUI

private enum DemoCategory: String, CaseIterable, Identifiable, Hashable {
    case privacy
    case text
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "隐私过滤"
        case .text: return "文本"
        case .image: return "图像"
        }
    }

    var subtitle: String {
        switch self {
        case .privacy: return "体验OpenAI Privacy Filter模型，对个人身份信息检测和脱敏"
        case .text: return "总结、改写、翻译，以及生成回复。"
        case .image: return "围绕照片、截图、海报和场景内容进行理解与问答。"
        }
    }

    var symbol: String {
        switch self {
        case .privacy: return "lock.shield"
        case .text: return "text.bubble"
        case .image: return "photo.on.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .privacy: return .green
        case .text: return .blue
        case .image: return .purple
        }
    }

    var demos: [DemoExperience] {
        switch self {
        case .privacy:
            return []
        case .text:
            return [
                DemoExperience(
                    title: "总结一段文字",
                    subtitle: "把一段长文本压缩成简短摘要。",
                    prompt: "请把下面这段文字总结成 3 条简洁要点：\n\n[在这里粘贴文本]",
                    symbol: "text.quote",
                    requiresImage: false,
                    intro: "粘贴任意段落、笔记或消息内容，让模型提炼重点。"
                ),
                DemoExperience(
                    title: "翻译文本",
                    subtitle: "在中文和英文之间自然转换。",
                    prompt: "请把下面这段文字翻译成自然流畅的英文，并保留原意：\n\n[在这里粘贴文本]",
                    symbol: "globe",
                    requiresImage: false,
                    intro: "适合展示手机端侧模型在语言转换上的即时能力。"
                ),
                DemoExperience(
                    title: "改写语气",
                    subtitle: "让消息更清晰、更礼貌，或更直接。",
                    prompt: "请把下面这段话改写得更礼貌、更专业：\n\n[在这里粘贴文本]",
                    symbol: "wand.and.stars",
                    requiresImage: false,
                    intro: "用于展示模型在不改变原意的前提下调整表达风格。"
                ),
                DemoExperience(
                    title: "提炼关键信息",
                    subtitle: "找出结论、行动项或最重要的信息。",
                    prompt: "阅读下面内容，并提炼主要结论与下一步行动：\n\n[在这里粘贴文本]",
                    symbol: "list.bullet.rectangle",
                    requiresImage: false,
                    intro: "适合会议记录、笔记和长消息整理。"
                ),
                DemoExperience(
                    title: "生成一条回复",
                    subtitle: "为邮件或聊天生成简短回复。",
                    prompt: "请为下面这段消息写一条简短、友好的回复：\n\n[在这里粘贴文本]",
                    symbol: "arrowshape.turn.up.left",
                    requiresImage: false,
                    intro: "适合展示手机上轻量写作辅助的实用感。"
                )
            ]
        case .image:
            return [
                DemoExperience(
                    title: "描述一张照片",
                    subtitle: "解释图片里正在发生什么。",
                    prompt: "请描述这张图片里正在发生什么，并指出最重要的细节。",
                    symbol: "photo",
                    requiresImage: true,
                    intro: "添加一张照片后，让模型用自然语言概括场景内容。"
                ),
                DemoExperience(
                    title: "围绕图片提问",
                    subtitle: "针对视觉内容提出一个具体问题。",
                    prompt: "请根据这张图片回答：其中最关键的物体或动作是什么？",
                    symbol: "questionmark.bubble",
                    requiresImage: true,
                    intro: "更适合展示模型对特定视觉问题的理解，而不只是泛泛描述。"
                ),
                DemoExperience(
                    title: "解释一张截图",
                    subtitle: "概括一张 App 或网页截图在展示什么。",
                    prompt: "请解释这张截图展示了什么，并总结其中最重要的信息。",
                    symbol: "macwindow.on.rectangle",
                    requiresImage: true,
                    intro: "适合展示模型对界面和截图内容的理解能力。"
                ),
                DemoExperience(
                    title: "读取海报或菜单",
                    subtitle: "从信息密集的图片中提取核心内容。",
                    prompt: "请阅读这张图片，并总结其中包含的关键信息。",
                    symbol: "menucard",
                    requiresImage: true,
                    intro: "适合海报、菜单、通知和其他文字较多的真实场景图片。"
                ),
                DemoExperience(
                    title: "发现重要细节",
                    subtitle: "从复杂场景中找出最值得注意的信息。",
                    prompt: "请观察这张图片，并告诉我其中最值得注意的细节。",
                    symbol: "eye",
                    requiresImage: true,
                    intro: "适合展示模型在复杂视觉场景中的注意力选择能力。"
                )
            ]
        }
    }
}

private struct DemoExperience: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let prompt: String
    let symbol: String
    let requiresImage: Bool
    let intro: String

    var id: String { title }
}

struct HomeView: View {
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HeroSection()

                    VStack(alignment: .leading, spacing: 14) {
                        Text("体验入口")
                            .font(.title2.bold())
                        Text("从一种能力出发，进入具体 demo，感受手机端侧 AI 的效果与速度。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        ForEach(DemoCategory.allCases) { category in
                            NavigationLink(value: category) {
                                CategoryCard(category: category)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("自由探索")
                            .font(.title3.bold())
                        Text("如果你已经有明确想测试的内容，可以直接进入聊天。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NavigationLink {
                            ChatScreen(viewModel: chat, title: "聊天")
                        } label: {
                            Label("进入聊天", systemImage: "message")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("体验馆")
            .navigationDestination(for: DemoCategory.self) { category in
                if category == .privacy {
                    PrivacyFilterDemoView()
                } else {
                    DemoCategoryView(category: category, chat: chat)
                }
            }
            .navigationDestination(for: DemoExperience.self) { demo in
                DemoChatView(chat: chat, demo: demo)
            }
        }
    }
}

private struct HeroSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在手机本地体验 AI 能力")
                .font(.largeTitle.bold())
            Text("看看端侧模型能做什么、回答效果如何，以及在真实任务里的响应速度。")
                .font(.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                HeroBadge(label: "本地运行", systemImage: "iphone")
                HeroBadge(label: "文本与图像", systemImage: "sparkles")
                HeroBadge(label: "内置性能指标", systemImage: "speedometer")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct HeroBadge: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct CategoryCard: View {
    let category: DemoCategory

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: category.symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(category.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(category.tint)

            VStack(alignment: .leading, spacing: 6) {
                Text(category.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(category.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct DemoCategoryView: View {
    let category: DemoCategory
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        List {
            Section {
                Text(category.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)

            Section("选择一个 demo") {
                ForEach(category.demos) { demo in
                    NavigationLink(value: demo) {
                        DemoRow(demo: demo)
                    }
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
    }
}

private struct DemoRow: View {
    let demo: DemoExperience

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: demo.symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(demo.title)
                    .font(.headline)
                Text(demo.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DemoChatView: View {
    @ObservedObject var chat: ChatViewModel
    let demo: DemoExperience
    @State private var hasPrepared = false

    var body: some View {
        ChatScreen(
            viewModel: chat,
            title: demo.title,
            introTitle: demo.subtitle,
            introText: demo.intro,
            requiresImage: demo.requiresImage
        )
        .onAppear {
            guard !hasPrepared else { return }
            hasPrepared = true
            chat.startDemo(prompt: demo.prompt)
        }
    }
}
