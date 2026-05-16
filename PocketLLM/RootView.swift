import SwiftUI

struct RootView: View {
    @StateObject private var appModel = AppModel()

    var body: some View {
        RootContentView(chat: appModel.chat, modelStore: appModel.modelStore)
            .environmentObject(appModel)
    }
}

private struct RootContentView: View {
    @ObservedObject var chat: ChatViewModel
    let modelStore: ModelStore

    var body: some View {
        ZStack {
            TabView {
                HomeView(chat: chat)
                    .tabItem {
                        Label("Explore", systemImage: "sparkles.rectangle.stack")
                    }

                ModelsView(modelStore: modelStore)
                    .tabItem {
                        Label("Models", systemImage: "square.and.arrow.down")
                    }
            }

            if chat.isSwitchingModel {
                ChatLoadingOverlay(message: chat.modelLoadingMessage)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }
}

#Preview {
    RootView()
}
