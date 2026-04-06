import SwiftUI

struct RootView: View {
    @StateObject private var appModel = AppModel()

    var body: some View {
        TabView {
            ChatView(viewModel: appModel.chat)
                .tabItem {
                    Label("Chat", systemImage: "message")
                }

            ModelsView(modelStore: appModel.modelStore)
                .tabItem {
                    Label("Models", systemImage: "square.and.arrow.down")
                }

            SettingsView(settings: appModel.settings)
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
        }
        .environmentObject(appModel)
    }
}

#Preview {
    RootView()
}
