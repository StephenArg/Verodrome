import Foundation

public enum CacheFileKind: String, Sendable {
    case song
    case episode
    case artwork
    case lyrics
}

public enum CacheFileManagerError: Error, Sendable {
    case invalidPath
    case fileNotFound
}

public final class CacheFileManager: @unchecked Sendable {
    public static let shared = CacheFileManager()

    private let fileManager: FileManager
    private let rootDirectory: URL

    public init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootDirectory = base.appendingPathComponent("Verodrome/Cache", isDirectory: true)
        }
        try? createRootIfNeeded()
    }

    public func accountDirectory(for accountKey: AccountInfo.Key) -> URL {
        rootDirectory
            .appendingPathComponent(accountKey.serverHash, isDirectory: true)
            .appendingPathComponent(accountKey.userHash, isDirectory: true)
    }

    public func directory(for accountKey: AccountInfo.Key, kind: CacheFileKind) -> URL {
        accountDirectory(for: accountKey).appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    @discardableResult
    public func ensureAccountDirectories(for accountKey: AccountInfo.Key) throws -> URL {
        let accountURL = accountDirectory(for: accountKey)
        try fileManager.createDirectory(at: accountURL, withIntermediateDirectories: true)
        for kind in [CacheFileKind.song, .episode, .artwork, .lyrics] {
            let url = directory(for: accountKey, kind: kind)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try moveExcludedFromBackup(url: url)
        }
        try moveExcludedFromBackup(url: accountURL)
        return accountURL
    }

    public func fileURL(for accountKey: AccountInfo.Key, kind: CacheFileKind, relativePath: String) -> URL {
        directory(for: accountKey, kind: kind).appendingPathComponent(relativePath)
    }

    public func playableFileURL(accountKey: AccountInfo.Key, relFilePath: String, isPodcastEpisode: Bool = false) -> URL {
        let kind: CacheFileKind = isPodcastEpisode ? .episode : .song
        return fileURL(for: accountKey, kind: kind, relativePath: relFilePath)
    }

    @discardableResult
    public func deleteFile(at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        try fileManager.removeItem(at: url)
        return true
    }

    public func deleteRelativeFile(accountKey: AccountInfo.Key, kind: CacheFileKind, relativePath: String) throws {
        let url = fileURL(for: accountKey, kind: kind, relativePath: relativePath)
        try deleteFile(at: url)
    }

    public func cacheSize(for accountKey: AccountInfo.Key) throws -> Int64 {
        let accountURL = accountDirectory(for: accountKey)
        guard fileManager.fileExists(atPath: accountURL.path) else { return 0 }
        return try directorySize(at: accountURL)
    }

    public func totalCacheSize() throws -> Int64 {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return 0 }
        return try directorySize(at: rootDirectory)
    }

    public func moveExcludedFromBackup(url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    private func createRootIfNeeded() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try moveExcludedFromBackup(url: rootDirectory)
    }

    private func directorySize(at url: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
