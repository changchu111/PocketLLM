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

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    var text: String
    var attachments: [ChatAttachment]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        attachments: [ChatAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
    }
}
