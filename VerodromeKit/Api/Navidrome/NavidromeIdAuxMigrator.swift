import Foundation

/// Auxiliary state that lives outside the SwiftData store and the on-disk cache:
/// currently the persisted play queue JSON files (`queue-{accountKey}.json` and
/// `user-queue-{accountKey}.json`) under `VerodromeQueue`.
///
/// Handled here rather than inside `FilePlayerQueueStore` because a live actor-backed
/// store may not yet be attached to this account when the migration runs (the migration
/// hook fires *before* `switchToAccount`, which is what actually points the queue store
/// at a given account). Rewriting the on-disk JSON directly keeps the migration
/// deterministic and independent of when the store is initialized.
///
/// The `LibraryMutationOutbox` remap is *not* here — that store exposes a public actor
/// API (`remapIds`) so the hook calls it directly instead of poking at its file.
public enum NavidromeIdAuxMigrator {

    public struct AuxReport: Equatable, Sendable {
        public var queueItemsRewritten: Int = 0
        public var userQueueItemsRewritten: Int = 0
        public init() {}
    }

    /// Apply the ID map to the persisted play queue files for `accountKey`. Missing
    /// files are treated as an empty state (fresh install / never-played account); no
    /// error is raised.
    @discardableResult
    public static func apply(
        map: NavidromeIdMap,
        queueDirectory: URL,
        accountKey: String,
        fileManager: FileManager = .default
    ) throws -> AuxReport {
        var report = AuxReport()
        let songMap = map.forwardLookup(kind: .song)
        let episodeMap = map.forwardLookup(kind: .podcastEpisode)
        let radioMap = map.forwardLookup(kind: .radio)
        if songMap.isEmpty && episodeMap.isEmpty && radioMap.isEmpty { return report }

        let contextURL = queueDirectory.appendingPathComponent("queue-\(accountKey).json")
        let userURL = queueDirectory.appendingPathComponent("user-queue-\(accountKey).json")

        if fileManager.fileExists(atPath: contextURL.path) {
            report.queueItemsRewritten = try rewriteContextQueue(
                at: contextURL,
                songMap: songMap,
                episodeMap: episodeMap,
                radioMap: radioMap
            )
        }
        if fileManager.fileExists(atPath: userURL.path) {
            report.userQueueItemsRewritten = try rewriteUserQueue(
                at: userURL,
                songMap: songMap,
                episodeMap: episodeMap,
                radioMap: radioMap
            )
        }
        return report
    }

    // MARK: - Context queue (`PersistedPlayerQueue`)

    /// The context queue is written by `FilePlayerQueueStore` as an encoded
    /// `PersistedPlayerQueue`. We deserialize with `JSONSerialization` rather than the
    /// codable type so that shape drift in `PersistedPlayerQueue` (fields added later)
    /// does not fail migration — the migration is a value-preserving rewrite.
    private static func rewriteContextQueue(
        at url: URL,
        songMap: [String: String],
        episodeMap: [String: String],
        radioMap: [String: String]
    ) throws -> Int {
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }

        var rewritten = 0
        for arrayField in ["context", "user", "podcast", "unshuffledContext"] {
            guard var items = root[arrayField] as? [[String: Any]] else { continue }
            for i in items.indices {
                if remapItemInPlace(&items[i], songMap: songMap, episodeMap: episodeMap, radioMap: radioMap) {
                    rewritten += 1
                }
            }
            root[arrayField] = items
        }

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try outData.write(to: url, options: .atomic)
        return rewritten
    }

    // MARK: - User queue (bare `[QueueItem]`)

    private static func rewriteUserQueue(
        at url: URL,
        songMap: [String: String],
        episodeMap: [String: String],
        radioMap: [String: String]
    ) throws -> Int {
        let data = try Data(contentsOf: url)
        guard var items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        var rewritten = 0
        for i in items.indices {
            if remapItemInPlace(&items[i], songMap: songMap, episodeMap: episodeMap, radioMap: radioMap) {
                rewritten += 1
            }
        }
        let outData = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        try outData.write(to: url, options: .atomic)
        return rewritten
    }

    /// Rewrites `playableId` in-place based on the item's `kind`. Returns true when
    /// something actually changed. Also rewrites `artworkId` when it embeds a song id
    /// via the `embedded-{id}` convention.
    private static func remapItemInPlace(
        _ item: inout [String: Any],
        songMap: [String: String],
        episodeMap: [String: String],
        radioMap: [String: String]
    ) -> Bool {
        var changed = false
        let kind = (item["kind"] as? String) ?? "song"
        let mapping: [String: String]
        switch kind {
        case "podcastEpisode": mapping = episodeMap
        case "radio": mapping = radioMap
        default: mapping = songMap
        }
        if let playableId = item["playableId"] as? String,
           let newId = mapping[playableId] {
            item["playableId"] = newId
            changed = true
        }
        // Embedded artwork tokens embed the song id; remap alongside the playable id so
        // the queued row's art stays resolvable after the file is renamed.
        if let artworkId = item["artworkId"] as? String,
           artworkId.hasPrefix("embedded-") {
            let id = String(artworkId.dropFirst("embedded-".count))
            if let newId = songMap[id] {
                item["artworkId"] = "embedded-\(newId)"
                changed = true
            }
        }
        return changed
    }
}
