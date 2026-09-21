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
        else { return nil }

        let result = applyIfNeeded(to: song, lyrics: trimmed, settings: settings)
        if result.didChange {
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
    /// that just flipped to explicit. `verodromeQueueChanged` is what refills the prefetch
    /// window the same way a skip does.
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
        guard shouldRemoveNonCurrentFromQueue(
            hideExplicit: hideExplicit,
            didChange: didChange,
            status: status
        ) else { return }
        handler?.removeNonCurrent(playableId: playableId)
    }
}
