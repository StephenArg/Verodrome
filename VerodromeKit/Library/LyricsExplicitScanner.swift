import Foundation
import SwiftData

public struct LyricsExplicitScanProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var markedExplicit: Int
    public var flippedToClean: Int
    public var skippedNoLyrics: Int

    public init(
        completed: Int = 0,
        total: Int = 0,
        markedExplicit: Int = 0,
        flippedToClean: Int = 0,
        skippedNoLyrics: Int = 0
    ) {
        self.completed = completed
        self.total = total
        self.markedExplicit = markedExplicit
        self.flippedToClean = flippedToClean
        self.skippedNoLyrics = skippedNoLyrics
    }
}

/// Album-wide and "recheck explicit" lyrics scans. Sequential so LRCLIB is not flooded.
@MainActor
public enum LyricsExplicitScanner {
    public static func scanAlbum(songs: [Song], progress: ((LyricsExplicitScanProgress) -> Void)? = nil) async -> LyricsExplicitScanProgress {
        await scan(remoteIds: songs.map(\.remoteId), progress: progress)
    }

    public static func recheckExplicit(progress: ((LyricsExplicitScanProgress) -> Void)? = nil) async -> LyricsExplicitScanProgress {
        let explicitRaw = LyricsExplicitStatus.explicit.rawValue
        let ids: [String]
        if let storage = VerodromeKit.shared.storage {
            ids = (try? await storage.backgroundActor.perform { context in
                try context.fetch(
                    FetchDescriptor<Song>(
                        predicate: #Predicate<Song> { $0.lyricsExplicitStatusRaw == explicitRaw }
                    )
                ).map(\.remoteId)
            }) ?? []
        } else {
            ids = []
        }
        return await scan(remoteIds: ids, force: true, progress: progress)
    }

    /// - Parameter force: Ignore the stale/fresh check and re-evaluate every song that has lyrics.
    public static func scan(
        remoteIds: [String],
        force: Bool = false,
        progress: ((LyricsExplicitScanProgress) -> Void)? = nil
    ) async -> LyricsExplicitScanProgress {
        var result = LyricsExplicitScanProgress(total: remoteIds.count)
        progress?(result)
        guard !remoteIds.isEmpty else { return result }
        guard SettingsStore.shared.loadUserSettings().explicitDetectionEnabled else { return result }

        for remoteId in remoteIds {
            if Task.isCancelled { break }
            let outcome = await scanOne(remoteId: remoteId, force: force)
            result.completed += 1
            switch outcome {
            case .explicit:
                result.markedExplicit += 1
            case .flippedToClean:
                result.flippedToClean += 1
            case .skippedNoLyrics:
                result.skippedNoLyrics += 1
            case .unchanged:
                break
            }
            progress?(result)
        }
        return result
    }

    private enum Outcome {
        case explicit
        case flippedToClean
        case skippedNoLyrics
        case unchanged
    }

    private static func scanOne(remoteId: String, force: Bool) async -> Outcome {
        guard let lookup = await songLookup(remoteId: remoteId) else { return .skippedNoLyrics }
        let previous = lookup.status

        if !force,
           !LyricsExplicitEvaluator.needsEvaluation(
            status: lookup.status,
            checkedAt: lookup.checkedAt,
            wordListChangedAt: SettingsStore.shared.loadUserSettings().explicitWordListChangedAt,
            enabled: SettingsStore.shared.loadUserSettings().explicitDetectionEnabled
           ),
           lookup.status != .unknown {
            return .unchanged
        }

        guard let lyrics = await resolveLyrics(for: lookup) else { return .skippedNoLyrics }

        if force, let repository = VerodromeKit.shared.repository(),
           let account = try? VerodromeKit.shared.activeAccount(),
           let song = try? repository.resolveSong(remoteId: remoteId, account: account) {
            let settings = SettingsStore.shared.loadUserSettings()
            guard settings.explicitDetectionEnabled else { return .unchanged }
            let status = LyricsExplicitEvaluator.evaluate(lyrics: lyrics, settings: settings)
            let changed = song.lyricsExplicitStatus != status
            song.lyricsExplicitStatus = status
            song.lyricsExplicitCheckedAt = .now
            if changed {
                song.updatedAt = .now
                try? repository.save()
                NotificationCenter.default.post(name: .songMetadataRefreshed, object: remoteId)
            }
            LyricsExplicitEvaluator.syncLiveQueue(
                playableId: remoteId,
                isExplicit: song.isLyricsExplicit,
                didChange: changed,
                status: status,
                hideExplicit: settings.hideExplicitSongs
            )
            if status == .explicit { return .explicit }
            if previous == .explicit, status == .clean { return .flippedToClean }
            return .unchanged
        }

        guard let applied = LyricsExplicitEvaluator.applyToLibrary(playableId: remoteId, lyrics: lyrics) else {
            return .skippedNoLyrics
        }
        if applied.status == .explicit { return .explicit }
        if previous == .explicit, applied.status == .clean { return .flippedToClean }
        return .unchanged
    }

    private struct SongLookup {
        var remoteId: String
        var title: String
        var artistName: String?
        var albumTitle: String?
        var duration: TimeInterval
        var status: LyricsExplicitStatus
        var checkedAt: Date?
        var localFileURL: URL?
    }

    private static func songLookup(remoteId: String) -> SongLookup? {
        guard let repository = VerodromeKit.shared.repository(),
              let account = try? VerodromeKit.shared.activeAccount(),
              let song = try? repository.resolveSong(remoteId: remoteId, account: account)
        else { return nil }
        let fileURL: URL?
        if let cache = VerodromeKit.shared.playableCache {
            fileURL = cache.fileURL(forPlayableId: remoteId, kind: .song)
        } else {
            fileURL = nil
        }
        return SongLookup(
            remoteId: remoteId,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            duration: song.playDuration,
            status: song.lyricsExplicitStatus,
            checkedAt: song.lyricsExplicitCheckedAt,
            localFileURL: fileURL
        )
    }

    private static func resolveLyrics(for lookup: SongLookup) async -> String? {
        let lyricsCache = VerodromeKit.shared.lyricsCache
        let syncer = VerodromeKit.shared.activeLibrarySyncer as? (any LyricsProviding)
        let settings = SettingsStore.shared.loadUserSettings()
        let lrcLibQuery: LrcLibClient.Query?
        if settings.lrcLibLyricsEnabled {
            let title = lookup.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = lookup.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty, !artist.isEmpty {
                lrcLibQuery = LrcLibClient.Query(
                    trackName: title,
                    artistName: artist,
                    albumName: lookup.albumTitle,
                    duration: lookup.duration > 0 ? lookup.duration : nil
                )
            } else {
                lrcLibQuery = nil
            }
        } else {
            lrcLibQuery = nil
        }
        let fileURL = lookup.localFileURL
        return await LyricsLookup.resolve(
            playableId: lookup.remoteId,
            cache: lyricsCache,
            fetchFromServer: syncer.map { provider in
                { try await provider.fetchLyrics(playableId: lookup.remoteId) }
            },
            fetchFromLrcLib: lrcLibQuery.map { query in
                { await LrcLibClient.shared.fetchLyrics(query: query) }
            },
            embeddedLyrics: {
                guard let fileURL else { return nil }
                return EmbeddedTagExtractor.lyrics(from: fileURL)
            }
        )
    }
}
