import SwiftUI
import UIKit
import VerodromeKit

struct QueueView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    /// Dismisses the hosting sheet (full-player queue). Nil when embedded (e.g. iPad inspector).
    var onDismiss: (() -> Void)? = nil

    /// Toolbar Edit toggle. Off: row overflow menus. On: reorder grips and remove buttons.
    /// Owned as real state rather than a read-only binding: List drives it to `.transient`
    /// for the duration of an interactive drag, and swallowing that write leaves the list
    /// and its cells out of step — rows drop in late or draw empty.
    @State private var editMode: EditMode = .inactive
    @State private var selectedAlbumId: String?
    @State private var playlistTarget: Song?
    /// Token + distance to nudge the list when "Added to Queue" grows above the viewport.
    @State private var scrollBump = ScrollBump.zero

    /// Where "Added to Queue" is drawn. Extends the handler's waiting run to include the
    /// playhead when that row is itself user-queued, so the current song stays under the
    /// section header instead of popping out above it the moment it starts.
    private var userQueued: Range<Int> {
        let queue = player.queue
        let current = player.currentIndex
        let waiting = player.userQueuedRange
        guard queue.indices.contains(current), queue[current].isUserQueued else {
            return waiting
        }
        return current..<max(waiting.upperBound, current + 1)
    }

    /// The handler's run — rows still waiting after the playhead. Edit offsets go through
    /// this, not `userQueued`, so the playing track isn't treated as a movable queued row.
    private var editableUserQueued: Range<Int> { player.userQueuedRange }

    /// Identity of the playing row, so edits that only shift indices don't read as a
    /// change of track.
    private var currentEntryId: UUID? {
        guard player.queue.indices.contains(player.currentIndex) else { return nil }
        return player.queue[player.currentIndex].entryId
    }

    /// Counts that together tell an insert apart from a reorder.
    private var queueShape: QueueShape {
        QueueShape(total: player.queue.count, queued: userQueued.count)
    }

    /// Any non-empty queue can be edited — replaying the album / playlist rebuilds it.
    private var showsEditButton: Bool {
        player.isQueueReorderable
    }

    private var isEditing: Bool {
        editMode.isEditing && showsEditButton
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // One flat run so Next Up can reorder past "Added to Queue" into the head
                // (and the reverse). Landing inside the queued run still copies; leaving it
                // is ignored so those rows can't be dragged out.
                ForEach(rows) { entry in
                    switch entry {
                    case .header(let header):
                        headerRow(header)
                            .moveDisabled(true)
                            .deleteDisabled(true)
                    case .song(let item, let index):
                        row(item, at: index)
                            // A lifted row is snapshotted with its own background; without
                            // an opaque one the floating cell draws through to black.
                            .listRowBackground(Rectangle().fill(.background))
                            .moveDisabled(!isEditing)
                            .deleteDisabled(!canDelete(at: index))
                    }
                }
                .onMove(perform: handleMove)
                .onDelete(perform: handleDelete)
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
            .sheet(item: $playlistTarget) { song in
                PlaylistSelectorView { playlist in
                    Task {
                        try? await LibraryActions.shared.addSongs([song], to: playlist)
                        ActionToast.addedToPlaylist(playlist.name)
                    }
                }
            }
            .background {
                // List keeps contentOffset across inserts, so a new "Added to Queue" row
                // pushes everything at/below the insertion down. Bump the offset by that
                // growth so the song that was queued from stays visually put.
                QueueListScrollBump(bump: scrollBump)
            }
            .onAppear { scrollToCurrent(using: proxy) }
            // Keyed on which track is playing, not on its index: a reorder shifts every
            // index below the edit, and scrolling back to the playhead on each drop is
            // what made a placed row appear to jump away.
            .onChange(of: currentEntryId) { _, _ in
                scrollToCurrent(using: proxy)
            }
            .onChange(of: queueShape) { old, new in
                // Only a real insert into the run shifts content down. A reorder can also
                // change the run's length, and bumping the offset for that is a visible jolt.
                // Skip while editing: a drag-to-queue copy already placed the gap under the
                // finger, and nudging scroll on top of that is the jump that looks laggy.
                guard !isEditing else { return }
                guard new.total > old.total, new.queued > old.queued else { return }
                scrollBump = ScrollBump(
                    token: scrollBump.token &+ 1,
                    distance: insertedHeight(from: old.queued, to: new.queued)
                )
            }
            .onChange(of: showsEditButton) { _, canEdit in
                if !canEdit { editMode = .inactive }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if showsEditButton {
                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = isEditing ? .inactive : .active }
                    }
                }
                if let onDismiss {
                    Button("Close", action: onDismiss)
                }
            }
        }
    }

    // MARK: - Rows

    /// The queue as the list renders it: every track, with the group labels in the same
    /// run so a Next Up drag can travel past "Added to Queue" into the head.
    private var rows: [QueueEntry] {
        let queue = player.queue
        let queued = userQueued
        var entries: [QueueEntry] = []
        entries.reserveCapacity(queue.count + 2)
        for index in queue.indices {
            if !queued.isEmpty {
                if index == queued.lowerBound { entries.append(.header(.userQueued)) }
                if index == queued.upperBound { entries.append(.header(.nextUp)) }
            }
            entries.append(.song(queue[index], index: index))
        }
        return entries
    }

    private func headerRow(_ header: QueueSectionHeader) -> some View {
        Text(header.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    @ViewBuilder
    private func row(_ item: QueueItem, at offset: Int) -> some View {
        let status = downloadStatus(for: item)
        HStack(spacing: 0) {
            Button {
                player.jump(to: offset)
            } label: {
                EntityRow(
                    title: item.title,
                    subtitle: item.artist ?? "",
                    artworkURL: item.artworkId,
                    symbol: item.kind == .radio ? "dot.radiowaves.left.and.right" : "music.note",
                    isPlaying: player.currentItem?.entryId == item.entryId
                        || (player.currentItem == nil && player.currentIndex == offset),
                    downloadStatus: status
                )
            }
            .buttonStyle(.plain)

            // Editing gives the trailing edge to the reorder grip instead.
            if item.kind == .song, !isEditing {
                QueueRowMenu(
                    item: item,
                    // Menu only needs working/not — live progress would rebuild it each tick.
                    downloadStatus: menuDownloadStatus(status),
                    onOpenAlbum: { selectedAlbumId = $0 },
                    onAddToPlaylist: { playlistTarget = $0 }
                )
            }
        }
    }

    // MARK: - Editing

    private func canDelete(at index: Int) -> Bool {
        isEditing && index != player.currentIndex
    }

    /// Row drags arrive in list positions, which count the group labels; the player edits
    /// the queue itself, so both ends are translated back into queue positions first.
    private func handleMove(from source: IndexSet, to destination: Int) {
        let entries = rows
        let sources = source.compactMap { entries.indices.contains($0) ? entries[$0].queueIndex : nil }
        guard !sources.isEmpty else { return }

        let queued = userQueued
        let target = queueIndex(forDropAt: destination, in: entries)
        let fromQueued = sources.allSatisfy { queued.contains($0) }

        if fromQueued {
            // Stay inside the run. An outbound drop is ignored so the row snaps home.
            guard !queued.isEmpty, dropLandsInQueued(destination: destination, target: target, entries: entries) else {
                return
            }
            let clamped = min(max(target, queued.lowerBound), queued.upperBound)
            let editable = editableUserQueued
            // Waiting rows keep the user-queue path (rewrites only that side file). A drag
            // that involves the playing queued track has to use the absolute move.
            if sources.allSatisfy({ editable.contains($0) }) {
                player.moveUserQueued(
                    from: IndexSet(sources.map { $0 - editable.lowerBound }),
                    to: clamped - editable.lowerBound
                )
            } else {
                player.moveQueue(from: IndexSet(sources), to: clamped)
            }
            return
        }

        // Context → "Added to Queue": copy at the drop index. No animation — List already
        // opened a gap there for a move, and animating a snap-back + end-insert reads as lag.
        if dropLandsInQueued(destination: destination, target: target, entries: entries) {
            let items = sources.sorted().compactMap { player.queue.indices.contains($0) ? player.queue[$0] : nil }
            guard !items.isEmpty else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                player.addToQueueTemporarily(items, at: target)
            }
            return
        }

        // Crossing past the run (Next Up ↔ head) lands outside it — a normal context move.
        player.moveQueue(from: IndexSet(sources), to: target)
    }

    private func handleDelete(_ offsets: IndexSet) {
        let entries = rows
        let indices = offsets.compactMap { entries.indices.contains($0) ? entries[$0].queueIndex : nil }
        guard !indices.isEmpty else { return }

        let editable = editableUserQueued
        if indices.allSatisfy({ editable.contains($0) }) {
            player.removeUserQueued(at: IndexSet(indices.map { $0 - editable.lowerBound }))
        } else {
            player.removeFromQueue(at: IndexSet(indices))
        }
    }

    /// Where a drop between list rows lands in the queue: the position of the next track
    /// at or after it, so releasing on a group label means "before the group".
    private func queueIndex(forDropAt destination: Int, in entries: [QueueEntry]) -> Int {
        for entry in entries.dropFirst(min(destination, entries.count)) {
            if let index = entry.queueIndex { return index }
        }
        return player.queue.count
    }

    /// True when the gap the user released in belongs to "Added to Queue" — the section
    /// header or any of its songs. The "Next Up" header and everything after it stay a
    /// normal context reorder (including jumping past into the head).
    private func dropLandsInQueued(destination: Int, target: Int, entries: [QueueEntry]) -> Bool {
        let queued = userQueued
        guard !queued.isEmpty else { return false }
        if entries.indices.contains(destination), case .header(.userQueued) = entries[destination] {
            return true
        }
        // Destination is the index after the gap; the row above it is what was hovered.
        let above = destination - 1
        if entries.indices.contains(above) {
            switch entries[above] {
            case .header(.userQueued): return true
            case .song(_, let index) where queued.contains(index): return true
            default: break
            }
        }
        return queued.contains(target)
    }

    // MARK: - Scrolling

    /// How far downstream content shifts when the user-queued run grows. The first add also
    /// introduces the section labels, which take space of their own.
    private func insertedHeight(from oldCount: Int, to newCount: Int) -> CGFloat {
        let addedSongs = CGFloat(newCount - oldCount) * Self.estimatedSongRowHeight
        guard oldCount == 0 else { return addedSongs }
        var labels = Self.estimatedHeaderHeight // "Added to Queue"
        // "Next Up" only appears when context tracks remain after the new run.
        if userQueued.upperBound < player.queue.count {
            labels += Self.estimatedHeaderHeight
        }
        return addedSongs + labels
    }

    private static let estimatedSongRowHeight: CGFloat = 64
    private static let estimatedHeaderHeight: CGFloat = 36

    /// Pins the playing track as the top row — or the "Added to Queue" header when the
    /// playhead sits in that section, so the label stays above the current song instead
    /// of scrolling away. Near the end of the list the scroll clamps.
    private func scrollToCurrent(using proxy: ScrollViewProxy) {
        // Keyed off the playhead rather than `currentItem`: a queue tap moves the index
        // right away while the engine reports the new track a beat later, so the item
        // still names the row that was playing before the tap. Read at scroll time so a
        // relocated "Added to Queue" run is already accounted for.
        // List needs a layout pass before cells register for scrollTo.
        DispatchQueue.main.async {
            guard player.queue.indices.contains(player.currentIndex) else { return }
            if userQueued.contains(player.currentIndex) {
                proxy.scrollTo(QueueSectionHeader.userQueued, anchor: .top)
            } else {
                proxy.scrollTo(player.queue[player.currentIndex].entryId, anchor: .top)
            }
        }
    }

    // MARK: - Download state

    /// Collapse live download fractions so the overflow menu isn't rebuilt every progress tick.
    private func menuDownloadStatus(_ status: DownloadStatus?) -> DownloadStatus {
        guard let status else { return .none }
        if case .downloading = status { return .downloading(0) }
        return status
    }

    /// Library songs only — radio and the like stay unmarked. A file kept offline by
    /// the user gets the download arrow; a queue-prefetch / stream cache gets a drive
    /// glyph so the two don't look the same.
    private func downloadStatus(for item: QueueItem) -> DownloadStatus? {
        guard item.kind == .song else { return nil }
        let cache = VerodromeKit.shared.playableCache
        let hasFile = cache?.hasPlayableFile(id: item.playableId, kind: item.kind) == true
        let status = downloadCenter.status(for: item.playableId, isDownloaded: hasFile)
        switch status {
        case .downloaded:
            // `DownloadCenter` treats any on-disk file as downloaded; only pinned
            // reasons are a real keep-forever download.
            if cache?.isUserPinned(id: item.playableId, kind: item.kind) == true {
                return .downloaded
            }
            return hasFile ? .cached : DownloadStatus.none
        case .none:
            return hasFile ? .cached : DownloadStatus.none
        default:
            return status
        }
    }
}

private enum QueueSectionHeader: Hashable {
    case userQueued
    case nextUp

    var title: String {
        switch self {
        case .userQueued: return "Added to Queue"
        case .nextUp: return "Next Up"
        }
    }
}

private struct ScrollBump: Equatable {
    var token: Int
    var distance: CGFloat

    static let zero = ScrollBump(token: 0, distance: 0)
}

private struct QueueShape: Equatable {
    var total: Int
    var queued: Int
}

/// Nudges the enclosing list's contentOffset when "Added to Queue" grows, so rows at or
/// below the insertion — including the song that was just queued from — stay visually put.
private struct QueueListScrollBump: UIViewRepresentable {
    var bump: ScrollBump

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Keep a live content-height baseline so the next insert can bump by what the
        // list actually grew, not only the estimate.
        if let scrollView = uiView.enclosingScrollView(),
           context.coordinator.lastToken == bump.token {
            context.coordinator.lastContentHeight = scrollView.contentSize.height
        }

        guard bump.distance > 0, context.coordinator.lastToken != bump.token else { return }
        context.coordinator.lastToken = bump.token
        let estimated = bump.distance
        let previousHeight = context.coordinator.lastContentHeight
        // Wait for the list to finish inserting so contentSize reflects the new rows;
        // bumping against the old size would clamp and leave the jump in place.
        DispatchQueue.main.async {
            guard let scrollView = uiView.enclosingScrollView() else { return }
            // Prefer the real growth when we had a baseline; fall back to the estimate
            // on the first bump (baseline 0 would otherwise look like the whole list grew).
            let grown = scrollView.contentSize.height - previousHeight
            let distance = previousHeight > 0 && grown > 0.5 && grown < estimated * 3
                ? grown
                : estimated
            var offset = scrollView.contentOffset
            offset.y += distance
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(
                minY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            offset.y = min(max(offset.y, minY), maxY)
            scrollView.setContentOffset(offset, animated: false)
            context.coordinator.lastContentHeight = scrollView.contentSize.height
        }
    }

    final class Coordinator {
        var lastToken = 0
        var lastContentHeight: CGFloat = 0
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }
}

/// A row of the queue list. Labels ride alongside the tracks so the whole list is one
/// `ForEach`, which is what lets a Next Up drag travel past "Added to Queue".
private enum QueueEntry: Identifiable {
    case header(QueueSectionHeader)
    /// `index` is the track's position in the player's queue, which the labels don't take up.
    case song(QueueItem, index: Int)

    var id: AnyHashable {
        switch self {
        case .header(let header): return header
        // `entryId` stays with the row across reorders. Position keys would make List
        // recycle cells by index and the trailing row often blanks until the next render.
        case .song(let item, _): return item.entryId
        }
    }

    var queueIndex: Int? {
        guard case .song(_, let index) = self else { return nil }
        return index
    }
}
