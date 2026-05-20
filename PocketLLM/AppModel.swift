import Foundation
import Combine

enum AppTab: Hashable {
    case explore
    case models
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: AppTab = .explore

    let sessionStore: SessionStore
    let settings = GenerationSettings()
    let modelStore = ModelStore()
    let chat: ChatViewModel

    init() {
        self.sessionStore = SessionStore(initialMessages: ChatViewModel.defaultMessages)
        self.chat = ChatViewModel(modelStore: modelStore, settings: settings, sessionStore: sessionStore)
    }
}
