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
    public var id: String { playableId + "|" + kind.rawValue }
    public var playableId: String
    public var kind: PlayableRef.Kind
    public var title: String
    public var artistName: String?
    public var albumName: String?
    public var duration: TimeInterval
    public var artworkId: String?
    /// When set, playback uses this URL directly (e.g. internet radio) instead of StreamURLProviding.
    public var directStreamURL: URL?

    public var isLiveStream: Bool { kind == .radio || directStreamURL != nil }

    public init(
        playableId: String,
        kind: PlayableRef.Kind = .song,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        duration: TimeInterval = 0,
        artworkId: String? = nil,
        directStreamURL: URL? = nil
    ) {
        self.playableId = playableId
        self.kind = kind
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.artworkId = artworkId
        self.directStreamURL = directStreamURL
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
