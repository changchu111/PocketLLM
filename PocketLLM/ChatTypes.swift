import Foundation

enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

enum ChatAttachmentType: String, Codable {
    case image
}

struct ChatAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    let type: ChatAttachmentType
    let localPath: String

    init(id: UUID = UUID(), type: ChatAttachmentType, localPath: String) {
        self.id = id
        self.type = type
        self.localPath = localPath
    }

    var url: URL {
        URL(fileURLWithPath: localPath)
    }
}

struct GenerationStats: Equatable, Codable {
    var ttftSeconds: Double
    var tokensPerSecond: Double
    var totalSeconds: Double
    var generatedTokenCount: Int
}

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: ChatRole
    var text: String
    var attachments: [ChatAttachment]
    var stats: GenerationStats?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        attachments: [ChatAttachment] = [],
        stats: GenerationStats? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.stats = stats
        self.createdAt = createdAt
    }
}
