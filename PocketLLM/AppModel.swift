import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    let sessionStore: SessionStore
    let settings = GenerationSettings()
    let modelStore = ModelStore()
    let chat: ChatViewModel

    init() {
        self.sessionStore = SessionStore(initialMessages: ChatViewModel.defaultMessages)
        self.chat = ChatViewModel(modelStore: modelStore, settings: settings, sessionStore: sessionStore)
    }
}
