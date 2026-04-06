import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    let settings = GenerationSettings()
    let modelStore = ModelStore()
    let chat: ChatViewModel

    init() {
        self.chat = ChatViewModel(modelStore: modelStore, settings: settings)
    }
}
