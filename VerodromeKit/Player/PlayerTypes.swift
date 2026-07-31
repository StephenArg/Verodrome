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


public struct QueueItem: Sendable, Hashable, Identifiable {
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
    /// True for items the user explicitly put in the queue ("Play Next" / "Add to Queue")
    /// rather than tracks that came in with the album, playlist, or other context. Only
    /// these may be removed from the queue.
    public var isUserQueued: Bool = false

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

public protocol PlayerQueuePersisting: AnyObject, Sendable {
    func loadQueue() async -> (
        context: [QueueItem],
        user: [QueueItem],
        podcast: [QueueItem],
        index: Int,
        generation: Int,
        repeatMode: RepeatMode,
        shuffleMode: ShuffleMode,
        playerMode: PlayerMode
    )
    func saveQueue(
        context: [QueueItem],
        user: [QueueItem],
        podcast: [QueueItem],
        index: Int,
        generation: Int,
        repeatMode: RepeatMode,
        shuffleMode: ShuffleMode,
        playerMode: PlayerMode
    ) async
}
