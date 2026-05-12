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
        TabView {
            HomeView(chat: chat)
                .tabItem {
                    Label("Explore", systemImage: "sparkles.rectangle.stack")
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
    }
}

#Preview {
    RootView()
}
