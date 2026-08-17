import Foundation

/// Sidecar lyrics files next to the other Caches roots (`VerodromePlayables`, `VerodromeArtwork`).
///
/// One UTF-8 `.lrc` file per playable id. Empty text is never written — a miss stays a miss so a
/// later server update can still land. Files are excluded from backup.
public final class LyricsCache: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            self.root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VerodromeLyrics", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? excludeFromBackup(self.root)
    }

    public func load(id: String) -> String? {
        let url = fileURL(for: id)
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// Stores non-empty lyrics. Whitespace-only / empty strings are ignored (no negative cache).
    @discardableResult
    public func store(id: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = fileURL(for: id)
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try excludeFromBackup(url)
            return true
        } catch {
            return false
        }
    }

    public func remove(id: String) {
        let url = fileURL(for: id)
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }

    public func fileURL(for id: String) -> URL {
        root.appendingPathComponent("\(sanitizedFileName(id)).lrc")
    }

    private func sanitizedFileName(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(resourceValues)
    }
}

/// Shared lookup order for playback and download write-through: disk → server → embedded ID3.
public enum LyricsLookup {
    /// Resolves lyrics without touching the network when `fetchFromServer` is nil.
    public static func resolve(
        playableId: String,
        cache: LyricsCache?,
        fetchFromServer: (() async throws -> String?)?,
        embeddedLyrics: (() -> String?)?
    ) async -> String? {
        if let cached = cache?.load(id: playableId) {
            return cached
        }

        if let fetchFromServer,
           let text = try? await fetchFromServer(),
           let normalized = nonEmpty(text) {
            cache?.store(id: playableId, text: normalized)
            return normalized
        }

        if let embedded = embeddedLyrics?(),
           let normalized = nonEmpty(embedded) {
            cache?.store(id: playableId, text: normalized)
            return normalized
        }

        return nil
    }

    /// Local-only path used at track start so artwork can appear before a network round-trip.
    public static func resolveLocal(
        playableId: String,
        cache: LyricsCache?,
        embeddedLyrics: (() -> String?)?
    ) -> String? {
        if let cached = cache?.load(id: playableId) {
            return cached
        }
        if let embedded = embeddedLyrics?(),
           let normalized = nonEmpty(embedded) {
            cache?.store(id: playableId, text: normalized)
            return normalized
        }
        return nil
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}
