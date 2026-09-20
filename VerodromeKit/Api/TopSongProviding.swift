import Foundation

/// Backends that can load Last.fm-backed popular tracks for an artist page.
public protocol TopSongProviding: AnyObject, Sendable {
    /// Library songs ranked as this artist's top tracks. Empty when the server has
    /// nothing (Last.fm unconfigured, or no matches).
    func topSongs(artistId: String, artistName: String, count: Int) async throws -> [IngestSong]
}
