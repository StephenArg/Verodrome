import Foundation

/// Backends that can build a song radio from a seed track (similar / instant-mix style).
public protocol SimilarSongProviding: AnyObject, Sendable {
    /// Songs similar to `id`. Empty when the server has nothing (e.g. Last.fm unconfigured).
    func similarSongs(toSongId id: String, count: Int) async throws -> [IngestSong]
}
