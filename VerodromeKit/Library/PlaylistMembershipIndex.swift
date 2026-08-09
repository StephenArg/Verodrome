import Combine
import Foundation
import SwiftData

/// Answers "which playlists is this song in?".
///
/// Neither Subsonic nor Ampache exposes a reverse lookup, so the only way to know is to
/// have every playlist's track list and invert it. `PlaylistItem` already holds that,
/// but walking it per lookup would fault a relationship for every row, so the inversion
/// is kept in memory and rebuilt when playlist contents change.
///
/// Only playlists this user can edit are counted. Smart and other-owned playlists can't
/// be added to or removed from, so including them would light up the player's button for
/// a song with no row in the sheet to explain it.
///
/// A rebuild is only ever *scheduled* by an invalidation, never performed by one: a full
/// catalog sync touches every playlist in turn, and this way that costs one rebuild at
/// the next read rather than one per playlist.
@MainActor
public final class PlaylistMembershipIndex: ObservableObject {
    public static let shared = PlaylistMembershipIndex()

    /// Bumped whenever the mapping changes so SwiftUI re-reads it.
    @Published public private(set) var version = 0

    private var index: [String: Set<String>] = [:]
    private var isStale = true
    private var republishTask: Task<Void, Never>?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .playlistItemsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        }
        center.addObserver(forName: .accountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reset() }
        }
    }

    // MARK: - Lookup

    /// Remote ids of the playlists containing `songId`.
    public func playlistIds(forSongId songId: String) -> Set<String> {
        rebuildIfNeeded()
        return index[songId] ?? []
    }

    public func isInAnyPlaylist(songId: String) -> Bool {
        rebuildIfNeeded()
        return !(index[songId] ?? []).isEmpty
    }

    public func isMember(songId: String, playlistId: String) -> Bool {
        rebuildIfNeeded()
        return index[songId]?.contains(playlistId) ?? false
    }

    // MARK: - Maintenance

    /// Applies a single membership change without a rebuild, so an optimistic toggle
    /// reflects immediately and can be reverted by calling this again with the old value.
    ///
    /// Any pending rebuild is settled first. Applying the change to an index that is about
    /// to be thrown away would lose it on the very next read, before the write it is
    /// standing in for has even reached the server.
    public func setMembership(songId: String, playlistId: String, isMember: Bool) {
        rebuildIfNeeded()
        if isMember {
            index[songId, default: []].insert(playlistId)
        } else {
            index[songId]?.remove(playlistId)
            if index[songId]?.isEmpty == true { index[songId] = nil }
        }
        version &+= 1
    }

    /// Marks the mapping stale and republishes shortly after.
    ///
    /// The delay is what keeps a catalog sync cheap: it rewrites every playlist's items in
    /// turn, and publishing each one would have any observing view force a full rebuild
    /// per playlist. Bursts collapse into a single refresh instead.
    public func invalidate() {
        isStale = true
        guard republishTask == nil else { return }
        republishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            self.republishTask = nil
            self.version &+= 1
        }
    }

    /// Drops everything. Used on account switch, where the previous account's remote ids
    /// are meaningless and could otherwise collide with the new one's.
    public func reset() {
        republishTask?.cancel()
        republishTask = nil
        index.removeAll()
        isStale = true
        version &+= 1
    }

    public func rebuildIfNeeded() {
        guard isStale else { return }
        // Staleness is only cleared by a rebuild that reached the store. Reading before the
        // kit has finished launching would otherwise cache an empty answer indefinitely.
        if rebuild() { isStale = false }
    }

    private func rebuild() -> Bool {
        guard let container = VerodromeKit.shared.storage?.container,
              let accountKey = AccountStore.shared.activeAccountKey()?.storageKey else { return false }
        index.removeAll()

        // A throwaway context rather than the main one. Playlist contents are rewritten by
        // the ingest actor on its own context, which deletes and recreates every row; the
        // main context is still holding the copies it just invalidated, and reading those
        // back gives items whose song no longer resolves. A fresh context has no cache to
        // be stale and simply reads what is committed.
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PlaylistItem>()
        // Without this every row faults its song and its playlist individually, which on a
        // library with a few large playlists is thousands of round trips to the store.
        descriptor.relationshipKeyPathsForPrefetching = [\PlaylistItem.song, \PlaylistItem.playlist]

        guard let items = try? context.fetch(descriptor) else { return false }
        let rejected = LibraryActions.shared.playlistsRejectedByServer
        for item in items {
            guard let songId = item.song?.remoteId,
                  let playlist = item.playlist,
                  playlist.isEditable,
                  !rejected.contains(playlist.remoteId),
                  playlist.account?.compoundKey == accountKey
            else { continue }
            index[songId, default: []].insert(playlist.remoteId)
        }
        return true
    }
}
