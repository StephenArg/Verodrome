import SwiftUI
import VerodromeKit

struct QueueView: View {
    @EnvironmentObject private var player: PlayerViewModel

    /// Dismisses the hosting sheet (full-player queue). Nil when embedded (e.g. iPad inspector).
    var onDismiss: (() -> Void)? = nil

    /// A context played in order is the album / playlist as the user asked for it, so it
    /// stays read-only. Shuffling is what turns the queue into something they arranged.
    private var isEditable: Bool { player.shuffleMode == .on }

    private var editMode: Binding<EditMode> {
        Binding(
            get: { isEditable ? .active : .inactive },
            set: { _ in }
        )
    }

    var body: some View {
        List {
            // `entryId` stays with the row across reorders. Offset keys make List recycle
            // cells by position and the trailing row often blanks until the next render.
            ForEach(Array(player.queue.enumerated()), id: \.element.entryId) { offset, item in
                Button {
                    player.jump(to: offset)
                } label: {
                    HStack(spacing: 8) {
                        EntityRow(
                            title: item.title,
                            subtitle: item.artist ?? "",
                            artworkURL: item.artworkId,
                            symbol: item.kind == .radio ? "dot.radiowaves.left.and.right" : "music.note",
                            isPlaying: player.currentItem?.entryId == item.entryId
                                || (player.currentItem == nil && player.currentIndex == offset)
                        )

                        // Temporary rows disappear once played; without a marker that
                        // reads as the queue losing tracks on its own.
                        if item.isEphemeral {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Plays once")
                        }
                    }
                }
                .buttonStyle(.plain)
                // Reorder grip is always shown while shuffled (edit mode stays active).
                .moveDisabled(!isEditable)
                // Only songs the user queued themselves can be taken back out.
                .deleteDisabled(!isEditable || !item.isUserQueued)
            }
            .onMove(perform: player.moveQueue)
            .onDelete(perform: player.removeFromQueue)
        }
        .listStyle(.plain)
        .environment(\.editMode, editMode)
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}
