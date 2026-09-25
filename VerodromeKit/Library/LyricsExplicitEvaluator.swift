import Foundation
import SwiftData

public struct LyricsExplicitApplyResult: Sendable, Equatable {
    public let didEvaluate: Bool
    public let didChange: Bool
    public let status: LyricsExplicitStatus

    public init(didEvaluate: Bool, didChange: Bool, status: LyricsExplicitStatus) {
        self.didEvaluate = didEvaluate
        self.didChange = didChange
        self.status = status
    }
}

/// Decides when a stored lyrics explicit rating is stale and writes a fresh one onto `Song`.
public enum LyricsExplicitEvaluator {
    public static func needsEvaluation(
        status: LyricsExplicitStatus,
        checkedAt: Date?,
        wordListChangedAt: Date?,
        enabled: Bool
    ) -> Bool {
        guard enabled else { return false }
        if status == .unknown { return true }
        guard let wordListChangedAt else { return false }
        guard let checkedAt else { return true }
        return checkedAt < wordListChangedAt
    }

    public static func evaluate(lyrics: String, settings: UserSettings) -> LyricsExplicitStatus {
        LyricsExplicitMatcher.isExplicit(lyrics, settings: settings) ? .explicit : .clean
    }

    /// Writes a new rating when the stored one is unknown or older than the word list.
    @discardableResult
    public static func applyIfNeeded(
        to song: Song,
        lyrics: String,
        settings: UserSettings,
        now: Date = .now
    ) -> LyricsExplicitApplyResult {
        let current = song.lyricsExplicitStatus
        guard needsEvaluation(
            status: current,
            checkedAt: song.lyricsExplicitCheckedAt,
            wordListChangedAt: settings.explicitWordListChangedAt,
            enabled: settings.explicitDetectionEnabled
        ) else {
            return LyricsExplicitApplyResult(didEvaluate: false, didChange: false, status: current)
        }

        let status = evaluate(lyrics: lyrics, settings: settings)
        let changed = song.lyricsExplicitStatus != status
        song.lyricsExplicitStatus = status
        song.lyricsExplicitCheckedAt = now
        return LyricsExplicitApplyResult(didEvaluate: true, didChange: changed, status: status)
    }

    /// Looks up the library song, evaluates, persists, and stamps matching queue rows.
    @MainActor
    @discardableResult
    public static func applyToLibrary(playableId: String, lyrics: String) -> LyricsExplicitApplyResult? {
        let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let settings = SettingsStore.shared.loadUserSettings()
        guard settings.explicitDetectionEnabled else { return nil }
        guard let repository = VerodromeKit.shared.repository(),
              let account = try? VerodromeKit.shared.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account)
        else {
            applyToUnstoredQueue(playableId: playableId, lyrics: trimmed, settings: settings)
            return nil
        }

        let result = applyIfNeeded(to: song, lyrics: trimmed, settings: settings)
        if result.didChange {
            AlbumExplicitTrackSync.refresh(for: song)
            song.updatedAt = .now
            try? repository.save()
            NotificationCenter.default.post(name: .songMetadataRefreshed, object: playableId)
        }
        syncLiveQueue(
            playableId: playableId,
            isExplicit: song.isLyricsExplicit,
            didChange: result.didChange,
            status: result.status,
            hideExplicit: settings.hideExplicitSongs
        )
        return result
    }

    /// Lyrics arrived for a queued song the library doesn't have yet (radio similar
    /// results are ingested after the row is appended). Still drop radio-continuation
    /// copies when the text is explicit, so Hide Explicit doesn't wait for ingest.
    @MainActor
    static func applyToUnstoredQueue(playableId: String, lyrics: String, settings: UserSettings) {
        guard settings.explicitDetectionEnabled, settings.hideExplicitSongs else { return }
        let status = evaluate(lyrics: lyrics, settings: settings)
        guard status == .explicit else { return }
        let handler = VerodromeKit.shared.queueHandler
        handler?.setLyricsExplicit(true, playableId: playableId)
        noteRadioExplicit(playableId)
        handler?.removeNonCurrentRadioContinuation(playableId: playableId)
    }

    /// Hide Explicit drops queued copies that just became explicit. The playing track is
    /// never removed — that is `PlayQueueHandler.removeNonCurrent`.
    public static func shouldRemoveNonCurrentFromQueue(
        hideExplicit: Bool,
        didChange: Bool,
        status: LyricsExplicitStatus
    ) -> Bool {
        hideExplicit && didChange && status == .explicit
    }

    /// Stamps matching queue rows and, when Hide Explicit is on, drops non-playing copies
    /// that just flipped to explicit. Radio-continuation rows are dropped whenever the
    /// song is confirmed explicit, including when the rating was already stored — those
    /// rows are appended after the fact and would otherwise stay. `verodromeQueueChanged`
    /// is what refills the prefetch window the same way a skip does.
    @MainActor
    public static func syncLiveQueue(
        playableId: String,
        isExplicit: Bool,
        didChange: Bool,
        status: LyricsExplicitStatus,
        hideExplicit: Bool
    ) {
        let handler = VerodromeKit.shared.queueHandler
        handler?.setLyricsExplicit(isExplicit, playableId: playableId)
        guard hideExplicit, status == .explicit else { return }
        noteRadioExplicit(playableId)
        if shouldRemoveNonCurrentFromQueue(
            hideExplicit: hideExplicit,
            didChange: didChange,
            status: status
        ) {
            handler?.removeNonCurrent(playableId: playableId)
        } else {
            handler?.removeNonCurrentRadioContinuation(playableId: playableId)
        }
    }

    /// Playable ids Hide Explicit has already rejected for radio continuation this session.
    /// Similar-song results are not in the library yet when the first lyrics pass runs, so
    /// the next top-up would append the same id again.
    @MainActor
    private static var radioExplicitSuppressed: Set<String> = []

    @MainActor
    static func noteRadioExplicit(_ playableId: String) {
        guard !playableId.isEmpty else { return }
        radioExplicitSuppressed.insert(playableId)
    }

    /// Drops confirmed-explicit rows from a radio-continuation batch when Hide Explicit is on.
    /// Also forgets the session suppression list when the setting is off.
    @MainActor
    public static func radioContinuationItems(_ items: [QueueItem]) -> [QueueItem] {
        let hideExplicit = SettingsStore.shared.hideExplicitSongs
        if !hideExplicit {
            radioExplicitSuppressed.removeAll()
            return items
        }
        return filteringRadioContinuation(
            items,
            hideExplicit: true,
            suppressedIds: radioExplicitSuppressed
        )
    }

    public static func filteringRadioContinuation(
        _ items: [QueueItem],
        hideExplicit: Bool,
        suppressedIds: Set<String> = []
    ) -> [QueueItem] {
        guard hideExplicit else { return items }
        return items.filter { item in
            !item.isLyricsExplicit && !suppressedIds.contains(item.playableId)
        }
    }
}

/// Keeps `Album.hasExplicitTrack` in step with confirmed song ratings.
public enum AlbumExplicitTrackSync {
    private static let defaultsKey = "album.explicitTrackBackfillDone"
    private static let gate = AlbumExplicitBackfillGate()

    /// Explicit turns the album flag on. Clean clears it only when no sibling track
    /// on that album is still explicit.
    @MainActor
    public static func refresh(for song: Song) {
        guard let album = song.album else { return }
        if song.isLyricsExplicit {
            album.hasExplicitTrack = true
            return
        }
        guard album.hasExplicitTrack else { return }
        album.hasExplicitTrack = album.songs.contains { $0.isLyricsExplicit }
    }

    /// One-time stamp of albums that already have a confirmed-explicit track, so badges
    /// show before the next lyrics check. Safe to call from every album list.
    public static func backfillIfNeeded() async {
        if UserDefaults.standard.bool(forKey: defaultsKey) { return }
        await gate.runOnce {
            if UserDefaults.standard.bool(forKey: defaultsKey) { return }
            let explicitRaw = LyricsExplicitStatus.explicit.rawValue
            do {
                _ = try await PersistentStorage.shared.backgroundActor.perform { context in
                    let songs = try context.fetch(
                        FetchDescriptor<Song>(
                            predicate: #Predicate<Song> { $0.lyricsExplicitStatusRaw == explicitRaw }
                        )
                    )
                    for song in songs {
                        song.album?.hasExplicitTrack = true
                    }
                    return songs.count
                }
                UserDefaults.standard.set(true, forKey: defaultsKey)
            } catch {
                // Leave the flag unset so a later launch can retry.
            }
        }
    }
}

private actor AlbumExplicitBackfillGate {
    private var task: Task<Void, Never>?

    func runOnce(_ work: @escaping @Sendable () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let created = Task { await work() }
        task = created
        await created.value
    }
}
