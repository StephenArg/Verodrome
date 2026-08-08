import SwiftUI
import VerodromeKit

struct QueueView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    /// Dismisses the hosting sheet (full-player queue). Nil when embedded (e.g. iPad inspector).
    var onDismiss: (() -> Void)? = nil

    /// Reorder handles for the added-to-queue section, turned on from its header. Editing
    /// is per-section in intent only — SwiftUI edit mode covers the whole list — so the
    /// context rows keep `moveDisabled` / `deleteDisabled` and stay untouched by it.
    @State private var isEditingUserQueued = false

    /// A context played in order is the album / playlist as the user asked for it, so it
    /// stays read-only. Shuffling is what turns the queue into something they arranged.
    private var isContextEditable: Bool { player.shuffleMode == .on }

    /// Rows the user added themselves, waiting between the playing track and the context.
    private var userQueued: Range<Int> { player.userQueuedRange }

    private var editMode: Binding<EditMode> {
        // Gated on the section still having rows: emptying it while editing would
        // otherwise leave the list in edit mode with nothing left to edit.
        let active = isContextEditable || (isEditingUserQueued && !userQueued.isEmpty)
        return Binding(
            get: { active ? .active : .inactive },
            set: { _ in }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if userQueued.isEmpty {
                    // Nothing added by hand: one plain run of rows, no headers to explain.
                    Section { contextRows(in: 0..<player.queue.count) }
                } else {
                    Section { contextRows(in: 0..<userQueued.lowerBound) }

                    Section {
                        userQueuedRows
                    } header: {
                        userQueuedHeader
                    }

                    if userQueued.upperBound < player.queue.count {
                        Section {
                            contextRows(in: userQueued.upperBound..<player.queue.count)
                        } header: {
                            Text("Next Up").textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, editMode)
            .onAppear { scrollToCurrent(using: proxy) }
            // Tapping another row (or any other playhead move) keeps the current track
            // pinned to the top — including after "Added to Queue" relocates under it.
            .onChange(of: player.currentIndex) { _, _ in
                scrollToCurrent(using: proxy, animated: true)
            }
            .onChange(of: userQueued.isEmpty) { _, isEmpty in
                if isEmpty { isEditingUserQueued = false }
            }
        }
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    /// Pins the playing track as the top row. Near the end of the list the scroll
    /// clamps, so the last tracks sit as low as the viewport allows.
    private func scrollToCurrent(using proxy: ScrollViewProxy, animated: Bool = false) {
        // Keyed off the playhead rather than `currentItem`: a queue tap moves the index
        // right away while the engine reports the new track a beat later, so the item
        // still names the row that was playing before the tap. Read at scroll time so a
        // relocated "Added to Queue" section is already accounted for.
        let scroll = {
            guard player.queue.indices.contains(player.currentIndex) else { return }
            let entryId = player.queue[player.currentIndex].entryId
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(entryId, anchor: .top)
                }
            } else {
                proxy.scrollTo(entryId, anchor: .top)
            }
        }
        // List needs a layout pass before cells register for scrollTo. After a jump that
        // relocates "Added to Queue", wait one more pass so the new section exists first.
        DispatchQueue.main.async {
            if animated {
                DispatchQueue.main.async(execute: scroll)
            } else {
                scroll()
            }
        }
    }

    private var userQueuedHeader: some View {
        HStack {
            Text("Added to Queue")
            Spacer()
            // While shuffled the whole list is already in edit mode, so the toggle would
            // claim to switch something that is on.
            if !isContextEditable {
                Button(isEditingUserQueued ? "Done" : "Edit") {
                    withAnimation { isEditingUserQueued.toggle() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .textCase(nil)
    }

    /// The added-to-queue section. Offsets from `onMove` / `onDelete` are relative to the
    /// section, which is the index space the player's user-queue edits take.
    @ViewBuilder
    private var userQueuedRows: some View {
        let range = userQueued
        ForEach(Array(zip(range, player.queue[range])), id: \.1.entryId) { offset, item in
            row(item, at: offset)
        }
        .onMove(perform: player.moveUserQueued)
        .onDelete(perform: player.removeUserQueued)
    }

    /// Rows belonging to the playing context. `onMove` / `onDelete` offsets are relative
    /// to `range`, so they are shifted back into whole-queue positions.
    @ViewBuilder
    private func contextRows(in range: Range<Int>) -> some View {
        let start = range.lowerBound
        // `entryId` stays with the row across reorders. Offset keys make List recycle
        // cells by position and the trailing row often blanks until the next render.
        ForEach(Array(zip(range, player.queue[range])), id: \.1.entryId) { offset, item in
            row(item, at: offset)
                // Reorder grip is always shown while shuffled (edit mode stays active).
                .moveDisabled(!isContextEditable)
                // Only songs the user queued themselves can be taken back out.
                .deleteDisabled(!isContextEditable || !item.isUserQueued)
        }
        .onMove { source, destination in
            player.moveQueue(from: IndexSet(source.map { $0 + start }), to: destination + start)
        }
        .onDelete { offsets in
            player.removeFromQueue(at: IndexSet(offsets.map { $0 + start }))
        }
    }

    private func row(_ item: QueueItem, at offset: Int) -> some View {
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
                downloadStatus: downloadStatus(for: item)
            )
        }
        .buttonStyle(.plain)
    }

    /// Same glyph album / playlist rows use next to the artist — only library songs
    /// carry a downloadable file; radio and the like stay unmarked.
    private func downloadStatus(for item: QueueItem) -> DownloadStatus? {
        guard item.kind == .song else { return nil }
        let isDownloaded = VerodromeKit.shared.playableCache?
            .fileURL(forPlayableId: item.playableId, kind: item.kind) != nil
        return downloadCenter.status(for: item.playableId, isDownloaded: isDownloaded)
    }
}
