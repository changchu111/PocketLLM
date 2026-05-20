import SwiftUI

struct RootView: View {
    @StateObject private var appModel = AppModel()

    var body: some View {
        RootContentView(chat: appModel.chat, modelStore: appModel.modelStore)
            .environmentObject(appModel)
    }
}

private struct RootContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var chat: ChatViewModel
    let modelStore: ModelStore

    var body: some View {
        ZStack {
            TabView(selection: $appModel.selectedTab) {
                HomeView(chat: chat)
                    .tabItem {
                        Label("Explore", systemImage: "sparkles.rectangle.stack")
                    }
                    .tag(AppTab.explore)

                ModelsView(modelStore: modelStore)
                    .tabItem {
                        Label("Models", systemImage: "square.and.arrow.down")
                    }
                    .tag(AppTab.models)
            }

            if chat.isSwitchingModel {
                ChatLoadingOverlay(message: chat.modelLoadingMessage)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if chat.showingModelSettings {
                ModelSettingsOverlay(viewModel: chat, isPresented: $chat.showingModelSettings)
                    .zIndex(20)
            }
        }
    }
}

#Preview {
    RootView()
}
