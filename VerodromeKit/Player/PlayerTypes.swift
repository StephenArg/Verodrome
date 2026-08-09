import Foundation

public enum PlayType: String, Sendable {
    case stream
    case cache
}

public enum RepeatMode: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case all = 1
    case one = 2
}

public enum ShuffleMode: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case on = 1
}

public enum PlayerMode: Int, Codable, CaseIterable, Sendable {
    case music = 0
    case podcast = 1
}

/// Sticky playback-speed options for the current play context.
public enum PlaybackSpeed {
    public static let options: [Float] = [2, 1.75, 1.5, 1.25, 1, 0.75, 0.5]
    /// Per-track pool used while Random mode is on (`1x` intentionally omitted).
    public static let randomOptions: [Float] = [
        0.8, 0.9, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9
    ]
    public static let randomMenuLabel = "Random"

    public static func clamp(_ rate: Float) -> Float {
        min(max(rate, 0.5), 2)
    }

    public static func isEqual(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    public static func randomRate() -> Float {
        randomOptions.randomElement() ?? 1.1
    }

    public static func label(for rate: Float) -> String {
        if isEqual(rate, 2) { return "2x" }
        if isEqual(rate, 1.75) { return "1.75x" }
        if isEqual(rate, 1.5) { return "1.5x" }
        if isEqual(rate, 1.25) { return "1.25x" }
        if isEqual(rate, 1) { return "1x" }
        if isEqual(rate, 0.75) { return ".75x" }
        if isEqual(rate, 0.5) { return ".5x" }
        let formatted = String(format: "%g", rate)
        return "\(formatted)x"
    }
}

/// Wall-clock sleep timer helpers for the popup player.
public enum SleepTimer {
    public static let maxHours = 23

    public static func duration(hours: Int, minutes: Int) -> TimeInterval {
        let h = min(max(hours, 0), maxHours)
        let m = min(max(minutes, 0), 59)
        return TimeInterval(h * 3600 + m * 60)
    }

    public static func label(hours: Int, minutes: Int) -> String {
        label(remaining: duration(hours: hours, minutes: minutes))
    }

    /// Formats a remaining interval as `"1h 29m"`, `"45m"`, or `"Off"` at zero.
    public static func label(remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        guard total > 0 else { return "Off" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }
}


public struct QueueItem: Sendable, Hashable, Identifiable, Codable {
    /// Playable identity (song / episode / …). Not unique in the queue when the same
    /// track is queued twice — use `entryId` for list row identity.
    public var id: String { playableId + "|" + kind.rawValue }
    /// Stable per queue-row identity so SwiftUI can reorder without recycling the wrong
    /// cell (offset-based ids make the last row vanish mid-drag).
    public var entryId: UUID
    public var playableId: String
    public var kind: PlayableRef.Kind
    public var title: String
    public var artistName: String?
    public var albumName: String?
    public var duration: TimeInterval
    public var artworkId: String?
    /// When set, playback uses this URL directly (e.g. internet radio) instead of StreamURLProviding.
    public var directStreamURL: URL?
    /// True for items the user explicitly put in the queue ("Add to Queue") rather than
    /// tracks that came in with the album, playlist, or other context. Only these may be
    /// removed from the queue.
    public var isUserQueued: Bool = false
    /// A temporary listen: the row leaves the queue as soon as playback moves past it,
    /// and its prefetched file is dropped with it. Set by "Add to Queue", which is meant
    /// to slot tracks in without permanently joining the queue.
    public var isEphemeral: Bool = false

    public var isLiveStream: Bool { kind == .radio || directStreamURL != nil }

    public init(
        playableId: String,
        kind: PlayableRef.Kind = .song,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        duration: TimeInterval = 0,
        artworkId: String? = nil,
        directStreamURL: URL? = nil,
        isUserQueued: Bool = false,
        isEphemeral: Bool = false,
        entryId: UUID = UUID()
    ) {
        self.entryId = entryId
        self.playableId = playableId
        self.kind = kind
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.artworkId = artworkId
        self.directStreamURL = directStreamURL
        self.isUserQueued = isUserQueued
        self.isEphemeral = isEphemeral
    }

    public init(from ref: PlayableRef) {
        self.init(
            playableId: ref.id,
            kind: ref.kind,
            title: ref.title,
            artistName: ref.artistName,
            albumName: ref.albumName,
            duration: ref.duration,
            artworkId: ref.coverArtId
        )
    }

    /// Convenience for UI call sites that use shorter label names.
    public init(
        playableID: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 0,
        artworkId: String? = nil,
        kind: PlayableRef.Kind = .song,
        directStreamURL: URL? = nil
    ) {
        self.init(
            playableId: playableID,
            kind: kind,
            title: title,
            artistName: artist,
            albumName: album,
            duration: duration,
            artworkId: artworkId,
            directStreamURL: directStreamURL
        )
    }

    /// Lenient on purpose: these rows are read back from a queue written by an earlier
    /// build, and a field added since then must not throw the whole queue away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try c.decodeIfPresent(UUID.self, forKey: .entryId) ?? UUID()
        playableId = try c.decode(String.self, forKey: .playableId)
        kind = try c.decodeIfPresent(PlayableRef.Kind.self, forKey: .kind) ?? .song
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artistName = try c.decodeIfPresent(String.self, forKey: .artistName)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        artworkId = try c.decodeIfPresent(String.self, forKey: .artworkId)
        directStreamURL = try c.decodeIfPresent(URL.self, forKey: .directStreamURL)
        isUserQueued = try c.decodeIfPresent(Bool.self, forKey: .isUserQueued) ?? false
        isEphemeral = try c.decodeIfPresent(Bool.self, forKey: .isEphemeral) ?? false
    }

    public var artist: String? { artistName }
    public var album: String? { albumName }
    public var artworkURL: URL? {
        guard let artworkId, let url = URL(string: artworkId) else { return nil }
        return url
    }

    public static func from(_ radio: Radio) -> QueueItem? {
        guard let raw = radio.streamURL, let url = URL(string: raw) else { return nil }
        return QueueItem(
            playableId: radio.remoteId,
            kind: .radio,
            title: radio.title,
            artistName: "Radio",
            duration: 0,
            artworkId: radio.artworkToken,
            directStreamURL: url
        )
    }
}

extension Array where Element == QueueItem {
    /// The run of user-queued rows sitting directly after `index`: what "Add to Queue"
    /// put in and playback hasn't reached yet.
    ///
    /// Taken as a contiguous run rather than every `isUserQueued` row, because a queued
    /// row further down — `enqueueLast` puts one at the very end — plays as part of the
    /// context around it. Presenting it alongside these would claim an order the queue
    /// doesn't have.
    public func userQueuedRun(after index: Int) -> Range<Int> {
        // Qualified: inside a Sequence extension, bare min/max are the instance methods.
        let start = Swift.min(Swift.max(0, index + 1), count)
        var end = start
        while end < count, self[end].isUserQueued { end += 1 }
        return start..<end
    }
}

/// The play queue as it is written between launches, so closing the app doesn't lose
/// what was playing.
public struct PersistedPlayerQueue: Codable, Sendable, Equatable {
    /// Context tracks only. The "Added to Queue" run is stored separately via
    /// `PlayerQueuePersisting.saveUserQueue` and merged back in on load.
    public var context: [QueueItem]
    /// Legacy field from when user-queued rows lived inside this snapshot. New writes
    /// leave it empty; load still reads it as a fallback when no side file exists.
    public var user: [QueueItem]
    public var podcast: [QueueItem]
    /// The context in the order it had before shuffle, so turning shuffle off after a
    /// relaunch restores the album / playlist order instead of freezing the shuffled one.
    public var unshuffledContext: [QueueItem]
    public var index: Int
    public var generation: Int
    public var repeatMode: RepeatMode
    public var shuffleMode: ShuffleMode
    public var playerMode: PlayerMode
    /// How far into the current track playback had reached.
    public var playbackPosition: TimeInterval

    public init(
        context: [QueueItem] = [],
        user: [QueueItem] = [],
        podcast: [QueueItem] = [],
        unshuffledContext: [QueueItem] = [],
        index: Int = 0,
        generation: Int = 0,
        repeatMode: RepeatMode = .off,
        shuffleMode: ShuffleMode = .off,
        playerMode: PlayerMode = .music,
        playbackPosition: TimeInterval = 0
    ) {
        self.context = context
        self.user = user
        self.podcast = podcast
        self.unshuffledContext = unshuffledContext
        self.index = index
        self.generation = generation
        self.repeatMode = repeatMode
        self.shuffleMode = shuffleMode
        self.playerMode = playerMode
        self.playbackPosition = playbackPosition
    }

    public var isEmpty: Bool { context.isEmpty && podcast.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = try c.decodeIfPresent([QueueItem].self, forKey: .context) ?? []
        user = try c.decodeIfPresent([QueueItem].self, forKey: .user) ?? []
        podcast = try c.decodeIfPresent([QueueItem].self, forKey: .podcast) ?? []
        unshuffledContext = try c.decodeIfPresent([QueueItem].self, forKey: .unshuffledContext) ?? []
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        repeatMode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        shuffleMode = try c.decodeIfPresent(ShuffleMode.self, forKey: .shuffleMode) ?? .off
        playerMode = try c.decodeIfPresent(PlayerMode.self, forKey: .playerMode) ?? .music
        playbackPosition = try c.decodeIfPresent(TimeInterval.self, forKey: .playbackPosition) ?? 0
    }
}

public protocol PlayerQueuePersisting: AnyObject, Sendable {
    /// The stored context queue, or nil when nothing was kept for the current account.
    /// Does not include the "Added to Queue" run — that lives in `loadUserQueue()`.
    func loadQueue() async -> PersistedPlayerQueue?
    func saveQueue(_ snapshot: PersistedPlayerQueue) async
    /// The "Added to Queue" rows waiting after the playhead. Kept in their own file so
    /// adding a track does not rewrite the whole context.
    func loadUserQueue() async -> [QueueItem]
    func saveUserQueue(_ items: [QueueItem]) async
    /// Forgets the stored queue, so the next launch starts empty.
    func clearQueue() async
}
