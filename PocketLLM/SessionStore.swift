import Foundation

struct ChatSessionSnapshot: Codable {
    let sessionID: UUID
    let startedAt: Date
    var messages: [ChatMessage]
}

@MainActor
final class SessionStore {
    private(set) var snapshot: ChatSessionSnapshot

    init(initialMessages: [ChatMessage]) {
        Self.cleanupStaleSessionFile()
        self.snapshot = ChatSessionSnapshot(
            sessionID: UUID(),
            startedAt: Date(),
            messages: initialMessages
        )
        persist()
    }

    var messages: [ChatMessage] {
        snapshot.messages
    }

    func updateMessages(_ messages: [ChatMessage]) {
        snapshot.messages = messages
        persist()
    }

    func reset(messages: [ChatMessage]) {
        snapshot = ChatSessionSnapshot(
            sessionID: UUID(),
            startedAt: Date(),
            messages: messages
        )
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder.pretty.encode(snapshot)
            let url = Self.sessionFileURL()
            try data.write(to: url, options: .atomic)
            try url.excludeFromBackup()
        } catch {
            print("SessionStore persist failed: \(error)")
        }
    }

    private static func cleanupStaleSessionFile() {
        let url = sessionFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func sessionFileURL() -> URL {
        let dir = (try? FileLocations.sessionDirectory(create: true)) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("current_session.json")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
