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
    let durationText: String

    var subtitle: String { "\(artistName) · \(albumTitle)" }
    var symbol: String { "music.note" }
    var trailingText: String? { durationText }

    init(song: Song) {
        id = song.compoundRemoteId
        remoteId = song.remoteId
        title = song.title
        sortTitle = song.sortTitle.isEmpty ? song.title : song.sortTitle
        sectionKey = (song.sortTitle.isEmpty ? song.title : song.sortTitle).sectionInitial
        artistName = song.artistName ?? "Unknown Artist"
        albumTitle = song.albumTitle ?? "Unknown Album"
        artworkToken = song.artworkToken
        duration = song.playDuration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        durationText = String(format: "%d:%02d", minutes, seconds)
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
