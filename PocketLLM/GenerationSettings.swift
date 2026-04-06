import Foundation
import Combine

@MainActor
final class GenerationSettings: ObservableObject {
    @Published var contextLength: Int32 = 4096
    @Published var maxNewTokens: Int32 = 512

    @Published var temperature: Float = 0.7
    @Published var topK: Int32 = 40
    @Published var topP: Float = 0.95
    @Published var presencePenalty: Float = 0.3
    @Published var frequencyPenalty: Float = 0.3

    @Published var seed: UInt32 = 1234
}
