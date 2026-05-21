import Foundation
import Combine

struct VLMRuntimeSettings {
    var imageMaxDimension: Float
    var useOriginalImage: Bool
    var imageMaxSlices: Int32
    var batchSize: Int32
    var ubatchSize: Int32
    var imageEvalBatchSize: Int32
    var forceMMProjCPU: Bool
}

@MainActor
final class GenerationSettings: ObservableObject {
    @Published var contextLength: Int32 = 4096
    @Published var maxNewTokens: Int32 = 512
    @Published var unlimitedMaxNewTokens: Bool = false

    @Published var temperature: Float = 0.7
    @Published var topK: Int32 = 40
    @Published var topP: Float = 0.95
    @Published var repeatPenalty: Float = 1.0
    @Published var presencePenalty: Float = 0.3
    @Published var frequencyPenalty: Float = 0.3

    @Published var seed: UInt32 = 1234

    @Published var miniCPMV46ImageSlices: Int32 = 9
    @Published var miniCPMV46MaxNewTokens: Int32 = 512
    @Published var miniCPMV46UnlimitedMaxNewTokens: Bool = false
    @Published var miniCPMV46Temperature: Float = 0.7
    @Published var miniCPMV46TopK: Int32 = 100
    @Published var miniCPMV46TopP: Float = 0.8
    @Published var miniCPMV46RepeatPenalty: Float = 1.05

    @Published var gemmaMaxNewTokens: Int32 = 4000
    @Published var gemmaUnlimitedMaxNewTokens: Bool = false
    @Published var gemmaTemperature: Float = 1.0
    @Published var gemmaTopK: Int32 = 64
    @Published var gemmaTopP: Float = 0.95
    @Published var gemmaUseGPU: Bool = true
    @Published var gemmaThinkingEnabled: Bool = false

    @Published var qwen35ImageMaxDimension: Float = 672
    @Published var qwen35UseOriginalImage: Bool = false
    @Published var qwen35ImageMaxSlices: Int32 = 1
    @Published var qwen35BatchSize: Int32 = 512
    @Published var qwen35UbatchSize: Int32 = 512
    @Published var qwen35ImageEvalBatchSize: Int32 = 512
    @Published var qwen35ForceMMProjCPU: Bool = false

    @Published var miniCPMV46ImageMaxDimension: Float = 768
    @Published var miniCPMV46UseOriginalImage: Bool = false
    @Published var miniCPMV46BatchSize: Int32 = 1024
    @Published var miniCPMV46UbatchSize: Int32 = 1024
    @Published var miniCPMV46ImageEvalBatchSize: Int32 = 1024
    @Published var miniCPMV46ForceMMProjCPU: Bool = false

    @Published var gemmaImageMaxDimension: Float = 768
    @Published var gemmaUseOriginalImage: Bool = false
    @Published var gemmaImageMaxSlices: Int32 = 1
    @Published var gemmaBatchSize: Int32 = 768
    @Published var gemmaUbatchSize: Int32 = 512
    @Published var gemmaImageEvalBatchSize: Int32 = 512
    @Published var gemmaForceMMProjCPU: Bool = false

    @Published var genericVLMImageMaxDimension: Float = 768
    @Published var genericVLMUseOriginalImage: Bool = false
    @Published var genericVLMImageMaxSlices: Int32 = 1
    @Published var genericVLMBatchSize: Int32 = 512
    @Published var genericVLMUbatchSize: Int32 = 512
    @Published var genericVLMImageEvalBatchSize: Int32 = 512
    @Published var genericVLMForceMMProjCPU: Bool = false
}
