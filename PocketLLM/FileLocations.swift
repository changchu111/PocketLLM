import Foundation

enum FileLocations {
    static func modelsDirectory(create: Bool = true) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Models", isDirectory: true)
        if create {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func modelFileURL(filename: String) -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        let dir = appSupport?.appendingPathComponent("Models", isDirectory: true)
        if let dir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(filename)
        }
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    static func attachmentsDirectory(create: Bool = true) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Attachments", isDirectory: true)
        if create {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func sessionDirectory(create: Bool = true) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Session", isDirectory: true)
        if create {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func attachmentFileURL(filename: String) -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        let dir = appSupport?.appendingPathComponent("Attachments", isDirectory: true)
        if let dir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(filename)
        }
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }
}

extension URL {
    func excludeFromBackup() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = self
        try copy.setResourceValues(values)
    }
}
