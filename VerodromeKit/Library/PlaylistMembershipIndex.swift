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
/// Rebuilds run on a background context and never on a read. Reading every playlist
/// item in the library takes long enough to drop frames, and it used to land on the main
/// thread in the middle of the player's sheet animation or a membership toggle. A read
/// therefore answers from the last completed build and `version` is bumped when a newer
/// one is ready.
@MainActor
public final class PlaylistMembershipIndex: ObservableObject {
    public static let shared = PlaylistMembershipIndex()

    /// Bumped whenever the mapping changes so SwiftUI re-reads it.
    @Published public private(set) var version = 0

    private var index: [String: Set<String>] = [:]
    private var isStale = true
    /// Bumped on every invalidation, so a build that was already reading the store when
    /// something changed can tell its answer may predate that change.
    private var generation = 0
    private var rebuildTask: Task<Void, Never>?
    /// Optimistic changes whose writes are still in flight. Laid over every build until
    /// the write returns, because a build that read the store first would otherwise put
    /// the old answer back while the server call is still running.
    private var pins: [MembershipKey: Pin] = [:]
    private var nextPinToken = 0

    /// A catalog sync rewrites every playlist's items in turn; waiting this long after
    /// the last change collapses the burst into one build.
    private static let debounceNanoseconds: UInt64 = 150_000_000

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

    /// Shows `isMember` immediately, runs `write`, and puts the previous answer back if
    /// it throws.
    ///
    /// The change is held over any rebuild that finishes while `write` is running. Once
    /// it returns the store is authoritative again, and a rebuild is scheduled to confirm.
    public func setMembership(
        songId: String,
        playlistId: String,
        isMember: Bool,
        awaiting write: () async throws -> Void
    ) async throws {
        let key = MembershipKey(songId: songId, playlistId: playlistId)
        let previous = index[songId]?.contains(playlistId) ?? false
        nextPinToken &+= 1
        let token = nextPinToken
        pins[key] = Pin(isMember: isMember, token: token)
        Self.apply(isMember, for: key, to: &index)
        version &+= 1

        do {
            try await write()
        } catch {
            // A later toggle of the same pair owns the answer now; leave it alone.
            if pins[key]?.token == token {
                pins[key] = nil
                Self.apply(previous, for: key, to: &index)
                version &+= 1
            }
            invalidate()
            throw error
        }
        if pins[key]?.token == token { pins[key] = nil }
        invalidate()
    }

    /// Marks the mapping stale and schedules a background rebuild.
    ///
    /// The current answer stays readable until the rebuild lands, so views don't blink
    /// back to "not in any playlist" in between.
    public func invalidate() {
        isStale = true
        generation &+= 1
        scheduleRebuild(after: Self.debounceNanoseconds)
    }

    /// Drops everything. Used on account switch, where the previous account's remote ids
    /// are meaningless and could otherwise collide with the new one's.
    public func reset() {
        index.removeAll()
        pins.removeAll()
        isStale = true
        generation &+= 1
        version &+= 1
        scheduleRebuild(after: 0)
    }

    /// Starts a rebuild if the mapping is stale and none is under way. Never blocks.
    public func rebuildIfNeeded() {
        guard isStale else { return }
        scheduleRebuild(after: 0)
    }

    // MARK: - Rebuild

    private func scheduleRebuild(after delay: UInt64) {
        // A running rebuild notices the bumped generation and goes round again.
        guard rebuildTask == nil else { return }
        rebuildTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            await self?.rebuildUntilCurrent()
            self?.rebuildTask = nil
        }
    }

    private func rebuildUntilCurrent() async {
        while isStale {
            // Staleness is only cleared by a rebuild that reached the store. Giving up here
            // rather than caching an empty answer lets the next read try again once the kit
            // has finished launching.
            guard let container = VerodromeKit.shared.storage?.container,
                  let accountKey = AccountStore.shared.activeAccountKey()?.storageKey else { return }
            let rejected = LibraryActions.shared.playlistsRejectedByServer
            let startedAt = generation

            let built = await Task.detached(priority: .userInitiated) {
                Self.build(container: container, accountKey: accountKey, rejected: rejected)
            }.value
            guard var built else { return }

            guard generation == startedAt else {
                // Something changed while this was reading, possibly after the rows it
                // read. Let the burst settle and read again.
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                continue
            }
            for (key, pin) in pins {
                Self.apply(pin.isMember, for: key, to: &built)
            }
            isStale = false
            if built != index {
                index = built
                version &+= 1
            }
        }
    }

    /// Reads on a throwaway context rather than the main one. Playlist contents are
    /// rewritten by the ingest actor on its own context, which deletes and recreates every
    /// row; the main context is still holding the copies it just invalidated, and reading
    /// those back gives items whose song no longer resolves. A fresh context has no cache
    /// to be stale and simply reads what is committed.
    private nonisolated static func build(
        container: ModelContainer,
        accountKey: String,
        rejected: Set<String>
    ) -> [String: Set<String>]? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PlaylistItem>()
        // Without this every row faults its song and its playlist individually, which on a
        // library with a few large playlists is thousands of round trips to the store.
        descriptor.relationshipKeyPathsForPrefetching = [\PlaylistItem.song, \PlaylistItem.playlist]

        guard let items = try? context.fetch(descriptor) else { return nil }
        var index: [String: Set<String>] = [:]
        for item in items {
            guard let songId = item.song?.remoteId,
                  let playlist = item.playlist,
                  playlist.isEditable,
                  !rejected.contains(playlist.remoteId),
                  playlist.account?.compoundKey == accountKey
            else { continue }
            index[songId, default: []].insert(playlist.remoteId)
        }
        return index
    }

    private nonisolated static func apply(
        _ isMember: Bool,
        for key: MembershipKey,
        to index: inout [String: Set<String>]
    ) {
        if isMember {
            index[key.songId, default: []].insert(key.playlistId)
        } else {
            index[key.songId]?.remove(key.playlistId)
            if index[key.songId]?.isEmpty == true { index[key.songId] = nil }
        }
    }
}

private struct MembershipKey: Hashable {
    let songId: String
    let playlistId: String
}

private struct Pin {
    let isMember: Bool
    /// Tells a finishing write whether a later toggle of the same pair has taken over.
    let token: Int
}
