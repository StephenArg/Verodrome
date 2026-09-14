import Foundation

/// Renames every on-disk artifact whose filename embeds a Navidrome song ID: audio files
/// across all quality variants under `VerodromePlayables/{kind}/{id}[.suffix]`, the
/// keys in `cache-meta.json`, lyrics sidecars under `VerodromeLyrics/{id}.lrc`, and the
/// embedded-artwork PNG under `VerodromeArtwork/embedded-{id}_s0`.
///
/// Runs after `NavidromeIdMigration.apply` has rewritten SwiftData, but the ordering
/// stays *filesystem then database* at the coordinator level: the file rename is
/// idempotent (a second pass sees the destination already exists and skips), whereas the
/// DB rewrite is destructive — once the row moves, the old ID is gone. Doing files first
/// means a crash between phases leaves files that can still be matched by their old
/// entries.
///
/// All operations are best-effort: a single missing file is not fatal (the on-disk state
/// tracks the DB, not the other way round), so per-file failures are counted and
/// reported. The only fatal error is failing to write `cache-meta.json` back to disk,
/// which would leave the cache in a torn state — that throws.
public enum NavidromeIdFileMigrator {

    /// Per-run statistics — surfaced for logging and test assertions.
    public struct FileReport: Equatable, Sendable {
        public var audioFilesRenamed: Int = 0
        public var audioFilesMissing: Int = 0
        public var audioFilesCollided: Int = 0
        public var metaKeysRewritten: Int = 0
        public var lyricsSidecarsRenamed: Int = 0
        public var embeddedArtworkRenamed: Int = 0
        public init() {}
    }

    /// Apply the ID map to every on-disk store.
    ///
    /// - Parameters:
    ///   - map: The remap. Only `.song`, `.podcastEpisode`, `.radio` entries drive file
    ///     work — the other kinds are DB-only.
    ///   - playablesRoot: `VerodromePlayables` (per-account cache root). Contains
    ///     `song/`, `podcastEpisode/`, `radio/` subdirectories and `cache-meta.json`.
    ///   - lyricsRoot: `VerodromeLyrics` (or nil to skip).
    ///   - artworkRoot: `VerodromeArtwork` (or nil to skip).
    ///   - fileManager: Injected for tests.
    @discardableResult
    public static func apply(
        map: NavidromeIdMap,
        playablesRoot: URL,
        lyricsRoot: URL?,
        artworkRoot: URL?,
        fileManager: FileManager = .default
    ) throws -> FileReport {
        var report = FileReport()

        let playableKinds: [(NavidromeIdMap.Kind, String)] = [
            (.song, "song"),
            (.podcastEpisode, "podcastEpisode"),
            (.radio, "radio"),
        ]

        // 1. Audio files. One enumeration per kind directory — the map is turned into a
        //    per-file lookup keyed by the leading ID component, so all quality variants
        //    (`{id}`, `{id}.mp3.320`, `.256`, `.192`) get renamed in one pass.
        for (kind, subdir) in playableKinds {
            let mapping = map.forwardLookup(kind: kind)
            guard !mapping.isEmpty else { continue }
            let dir = playablesRoot.appendingPathComponent(subdir, isDirectory: true)
            guard fileManager.fileExists(atPath: dir.path) else { continue }

            let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names {
                // Split on the first `.` to get the ID component; anything past is a
                // quality suffix (`.mp3.320`, `.mp3.256`, `.mp3.192`).
                let (idPart, tail) = splitAtFirstDot(name)
                guard let newId = mapping[idPart] else { continue }
                let newName = tail.isEmpty ? newId : "\(newId).\(tail)"
                let src = dir.appendingPathComponent(name)
                let dst = dir.appendingPathComponent(newName)

                if src.path == dst.path { continue }
                // Collision: the target already exists (a partial resumed run, or the
                // remote already had a canonical-id file present). Prefer the
                // destination — the syncer landing it means the server considers it
                // authoritative — and drop the source. Never overwrite: it would replace
                // a possibly-correct file with a stale variant.
                if fileManager.fileExists(atPath: dst.path) {
                    try? fileManager.removeItem(at: src)
                    report.audioFilesCollided += 1
                    continue
                }
                do {
                    try fileManager.moveItem(at: src, to: dst)
                    report.audioFilesRenamed += 1
                } catch {
                    report.audioFilesMissing += 1
                }
            }
        }

        // 2. cache-meta.json. Keys are `{kind}::{fileName}`; only the fileName portion
        //    embeds the ID and only the ID prefix of the fileName changes. Read, rewrite
        //    in-place, atomic write back. A stale rewrite loses download reasons /
        //    pinning, so this is the one thing that must not silently fail.
        let metaURL = playablesRoot.appendingPathComponent("cache-meta.json")
        if fileManager.fileExists(atPath: metaURL.path) {
            let data = try Data(contentsOf: metaURL)
            var meta = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var rewritten: [String: Any] = [:]
            rewritten.reserveCapacity(meta.count)

            for (key, value) in meta {
                let parts = key.components(separatedBy: "::")
                guard parts.count == 2 else { rewritten[key] = value; continue }
                let kindRaw = parts[0]
                let fileName = parts[1]
                let kind: NavidromeIdMap.Kind?
                switch kindRaw {
                case "song": kind = .song
                case "podcastEpisode": kind = .podcastEpisode
                case "radio": kind = .radio
                default: kind = nil
                }
                guard let kind else { rewritten[key] = value; continue }
                let mapping = map.forwardLookup(kind: kind)
                let (idPart, tail) = splitAtFirstDot(fileName)
                if let newId = mapping[idPart] {
                    let newFileName = tail.isEmpty ? newId : "\(newId).\(tail)"
                    let newKey = "\(kindRaw)::\(newFileName)"
                    // If another entry already claims the destination (shouldn't happen
                    // but the store makes no such promise), the newer touched-at wins.
                    if let existing = rewritten[newKey] as? [String: Any],
                       let newValue = value as? [String: Any],
                       let existingTouched = existing["touched"] as? String,
                       let newTouched = newValue["touched"] as? String,
                       existingTouched > newTouched {
                        // Keep the newer existing entry.
                    } else {
                        rewritten[newKey] = value
                    }
                    report.metaKeysRewritten += 1
                    meta[key] = nil
                } else {
                    rewritten[key] = value
                }
            }
            let outData = try JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys])
            try outData.write(to: metaURL, options: .atomic)
        }

        // 3. Lyrics sidecars — `{id}.lrc`. Song-scoped only; episodes / radios don't
        //    have lyrics files.
        if let lyricsRoot, fileManager.fileExists(atPath: lyricsRoot.path) {
            let songMap = map.forwardLookup(kind: .song)
            if !songMap.isEmpty {
                let names = (try? fileManager.contentsOfDirectory(atPath: lyricsRoot.path)) ?? []
                for name in names where name.hasSuffix(".lrc") {
                    let idPart = String(name.dropLast(4))
                    guard let newId = songMap[idPart] else { continue }
                    let src = lyricsRoot.appendingPathComponent(name)
                    let dst = lyricsRoot.appendingPathComponent("\(newId).lrc")
                    if src.path == dst.path { continue }
                    if fileManager.fileExists(atPath: dst.path) {
                        try? fileManager.removeItem(at: src)
                        continue
                    }
                    do {
                        try fileManager.moveItem(at: src, to: dst)
                        report.lyricsSidecarsRenamed += 1
                    } catch {
                        // Non-fatal — cache miss will re-fetch.
                    }
                }
            }
        }

        // 4. Embedded artwork — `embedded-{id}_s0` under the artwork cache root. These
        //    are the only art files that embed a song ID; server-fetched artwork uses
        //    the art token from the server (which the plan handles separately in the
        //    denormalized `artworkToken` string, without touching disk).
        if let artworkRoot, fileManager.fileExists(atPath: artworkRoot.path) {
            let songMap = map.forwardLookup(kind: .song)
            if !songMap.isEmpty {
                let names = (try? fileManager.contentsOfDirectory(atPath: artworkRoot.path)) ?? []
                for name in names where name.hasPrefix("embedded-") {
                    // Format: `embedded-{id}_s{size}`. Split off the `embedded-` prefix
                    // and the `_s…` suffix so only the ID is remapped.
                    let afterPrefix = String(name.dropFirst("embedded-".count))
                    guard let underscoreRange = afterPrefix.range(of: "_s") else { continue }
                    let id = String(afterPrefix[..<underscoreRange.lowerBound])
                    let sizeTail = String(afterPrefix[underscoreRange.lowerBound...])
                    guard let newId = songMap[id] else { continue }
                    let newName = "embedded-\(newId)\(sizeTail)"
                    let src = artworkRoot.appendingPathComponent(name)
                    let dst = artworkRoot.appendingPathComponent(newName)
                    if src.path == dst.path { continue }
                    if fileManager.fileExists(atPath: dst.path) {
                        try? fileManager.removeItem(at: src)
                        continue
                    }
                    do {
                        try fileManager.moveItem(at: src, to: dst)
                        report.embeddedArtworkRenamed += 1
                    } catch {
                        // Non-fatal — art will be re-extracted on next play if needed.
                    }
                }
            }
        }

        return report
    }

    /// Split a filename at the first `.` so `foo.mp3.320` returns (`foo`, `mp3.320`).
    /// Names with no dot return (name, "").
    private static func splitAtFirstDot(_ name: String) -> (id: String, tail: String) {
        guard let dot = name.firstIndex(of: ".") else { return (name, "") }
        let id = String(name[..<dot])
        let tail = String(name[name.index(after: dot)...])
        return (id, tail)
    }
}
