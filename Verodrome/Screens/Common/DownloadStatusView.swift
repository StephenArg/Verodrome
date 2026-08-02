import SwiftUI
import VerodromeKit

/// Download state as a single glyph: a spinner while the transfer is queued or
/// running, a filled arrow once the file is on disk.
///
/// Drawn by hand rather than with `ProgressView(value:)` because a determinate
/// circular progress view falls back to the indeterminate spinner on iOS, which
/// would hide how far along a track actually is.
struct DownloadStatusIcon: View {
    let status: DownloadStatus
    var size: CGFloat = 22
    /// Shows a hollow arrow when nothing is downloaded, for controls that must stay
    /// tappable. The player leaves this off so the row is empty until it has news.
    var showsIdleAffordance: Bool = false
    /// Explicit color so row glyphs keep the app accent when a parent view rebinds
    /// `.tint` to an artwork fill (album / playlist navigation chrome).
    var tint: Color = Color.accentColor

    private var lineWidth: CGFloat { max(1.5, size / 11) }

    var body: some View {
        Group {
            switch status {
            case .pending:
                IndeterminateRing(lineWidth: lineWidth, tint: tint)
            case .downloading(let progress):
                ProgressRing(progress: progress, lineWidth: lineWidth, tint: tint)
            case .partial:
                // Outline marks "some tracks", filled marks "all tracks".
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: size))
                    .foregroundStyle(tint)
                    .transition(.opacity.combined(with: .scale))
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(tint)
                    .transition(.opacity.combined(with: .scale))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: size))
                    .foregroundStyle(.orange)
            case .none:
                if showsIdleAffordance {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: size))
                        .foregroundStyle(Color.primary)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
        .frame(width: frameSize, height: frameSize)
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var frameSize: CGFloat {
        switch status {
        case .none where !showsIdleAffordance: return 0
        default: return size
        }
    }
}

/// Ring filled to `progress`, with a visible sliver at zero so a download that has
/// started but not reported bytes still reads as active.
private struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    var tint: Color = Color.accentColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.05, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
        }
        .padding(lineWidth / 2)
    }
}

/// Spinner for a download that is queued behind the concurrency limit.
private struct IndeterminateRing: View {
    let lineWidth: CGFloat
    var tint: Color = Color.accentColor
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
        }
        .padding(lineWidth / 2)
        .onAppear { spinning = true }
    }
}

/// Download glyph for one song, kept live from `DownloadCenter`. Tapping downloads,
/// cancels, or removes depending on where the song currently is.
struct SongDownloadStatusView: View {
    let song: Song
    var size: CGFloat = 22
    var showsIdleAffordance: Bool = false
    var isInteractive: Bool = true

    @ObservedObject private var downloadCenter = DownloadCenter.shared

    private var status: DownloadStatus {
        downloadCenter.status(for: song.remoteId, isDownloaded: song.isDownloadedLocally)
    }

    var body: some View {
        // Nothing to say yet, and no affordance asked for: render no view at all rather
        // than an empty one, which would still take its share of the stack's spacing.
        if status == .none, !showsIdleAffordance {
            EmptyView()
        } else if isInteractive {
            Button {
                Task { await LibraryActions.shared.downloadOrCancel(song: song) }
            } label: {
                DownloadStatusIcon(status: status, size: size, showsIdleAffordance: showsIdleAffordance)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
        } else {
            DownloadStatusIcon(status: status, size: size, showsIdleAffordance: showsIdleAffordance)
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .pending, .downloading: return "Cancel Download"
        case .partial: return "Partially Downloaded"
        case .downloaded: return "Remove Download"
        case .failed: return "Retry Download"
        case .none: return "Download"
        }
    }
}

/// Download state of a group of songs — an album, a playlist — reduced to the counts
/// its menu and status icon need.
@MainActor
struct SongsDownloadSummary {
    let total: Int
    let downloaded: Int
    let working: Int
    let failed: Int
    /// Combined 0...1 across the batch while anything is transferring.
    let progress: Double?

    init(songs: [Song], center: DownloadCenter) {
        self.init(
            songRemoteIds: songs.map(\.remoteId),
            downloadedIds: Set(songs.filter(\.isDownloadedLocally).map(\.remoteId)),
            trackTotal: songs.count,
            center: center
        )
    }

    /// Album rows often know a server `trackCount` before every song is in the local
    /// store — prefer that as the denominator so a 3-of-12 cache reads as partial.
    init(album: Album, center: DownloadCenter) {
        let songs = Array(album.songs)
        self.init(
            songRemoteIds: songs.map(\.remoteId),
            downloadedIds: Set(songs.filter(\.isDownloadedLocally).map(\.remoteId)),
            trackTotal: max(album.trackCount, songs.count),
            center: center
        )
    }

    init(
        songRemoteIds: [String],
        downloadedIds: Set<String>,
        trackTotal: Int,
        center: DownloadCenter
    ) {
        let ids = songRemoteIds
        // Session completions can land before a list refetch sees `relFilePath`.
        let effectiveDownloaded = downloadedIds.union(ids.filter { center.completedIds.contains($0) })
        total = max(trackTotal, ids.count)
        downloaded = effectiveDownloaded.count
        working = ids.filter { center.isWorking(on: $0) }.count
        failed = ids.filter { center.failedIds.contains($0) }.count
        progress = center.batchProgress(for: ids, downloadedIds: effectiveDownloaded)
    }

    var isWorking: Bool { working > 0 }
    var isFullyDownloaded: Bool { total > 0 && downloaded >= total }
    var isPartiallyDownloaded: Bool { downloaded > 0 && downloaded < total }
    var remaining: Int { max(0, total - downloaded) }

    var status: DownloadStatus {
        if isWorking { return .downloading(progress ?? 0) }
        if isFullyDownloaded { return .downloaded }
        if isPartiallyDownloaded { return .partial }
        if failed > 0 { return .failed }
        return .none
    }
}
