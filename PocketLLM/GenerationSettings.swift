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

    @Published var miniCPMV46ImageSlices: Int32 = 9

    @Published var gemmaMaxNewTokens: Int32 = 4000
    @Published var gemmaTemperature: Float = 1.0
    @Published var gemmaTopK: Int32 = 64
    @Published var gemmaTopP: Float = 0.95
    @Published var gemmaUseGPU: Bool = true
    @Published var gemmaThinkingEnabled: Bool = false
}
