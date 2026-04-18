import SwiftUI

struct RootView: View {
    @StateObject private var appModel = AppModel()

    var body: some View {
        RootContentView(chat: appModel.chat, modelStore: appModel.modelStore, settings: appModel.settings)
            .environmentObject(appModel)
    }
}

private struct RootContentView: View {
    @ObservedObject var chat: ChatViewModel
    let modelStore: ModelStore
    let settings: GenerationSettings

    var body: some View {
        ZStack {
            TabView {
                ChatView(viewModel: chat)
                    .tabItem {
                        Label("Chat", systemImage: "message")
                    }

                ModelsView(modelStore: modelStore)
                    .tabItem {
                        Label("Models", systemImage: "square.and.arrow.down")
                    }

                SettingsView(settings: settings)
                    .tabItem {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
            }

            if chat.isSwitchingModel {
                ModelLoadingOverlay(message: chat.modelLoadingMessage)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }
}

private struct ModelLoadingOverlay: View {
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

#Preview {
    RootView()
}
