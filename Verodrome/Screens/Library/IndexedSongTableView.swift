import SwiftUI
import VerodromeKit

/// Sendable row payload for large song lists (no SwiftData model retained).
/// Conforms to `LibraryRow` so `IndexedEntityTableView` can render it.
struct LibrarySongRowSnapshot: Identifiable, Sendable, Hashable, LibraryRow {
    let id: String
    let remoteId: String
    let title: String
    let sortTitle: String
    let sectionKey: String
    let artistName: String
    let albumTitle: String
    let artworkToken: String?
    let duration: TimeInterval
    let trailingText: String?
    let trailingRating: Int?

    var subtitle: String { "\(artistName) · \(albumTitle)" }
    var symbol: String { "music.note" }
    var playableId: String? { remoteId }

    init(song: Song, sort: LibrarySortOption) {
        id = song.compoundRemoteId
        remoteId = song.remoteId
        title = song.title
        sortTitle = song.sortTitle.isEmpty ? song.title : song.sortTitle
        sectionKey = (song.sortTitle.isEmpty ? song.title : song.sortTitle).sectionInitial
        artistName = song.artistName ?? "Unknown Artist"
        albumTitle = song.albumTitle ?? "Unknown Album"
        artworkToken = song.displayArtworkToken
        duration = song.playDuration
        trailingRating = sort == .ratingHighest ? song.rating : nil
        trailingText = trailingRating == nil ? Self.trailingText(for: song, sort: sort) : nil
    }

    /// Ordering by plays or rating sorts on a value the row otherwise never shows, so
    /// it takes the duration's place — an ordering you can't see the key for reads as
    /// arbitrary. Rating is the exception: it's drawn as tinted stars instead.
    private static func trailingText(for song: Song, sort: LibrarySortOption) -> String {
        switch sort {
        case .playsMost:
            return song.playCount == 1 ? "1 play" : "\(song.playCount) plays"
        default:
            let minutes = Int(song.playDuration) / 60
            let seconds = Int(song.playDuration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var queueItem: QueueItem {
        QueueItem(
            playableId: remoteId,
            kind: .song,
            title: title,
            artistName: artistName,
            albumName: albumTitle,
            duration: duration,
            artworkId: artworkToken
        )
    }
}
