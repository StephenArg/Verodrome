import XCTest
@testable import VerodromeKit

@MainActor
final class PlayQueueHandlerTests: XCTestCase {
    private static func songs(_ count: Int) -> [QueueItem] {
        (0..<count).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
    }

    func testReplaceAndAdvance() {
        let handler = PlayQueueHandler()
        let items = (0..<5).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 0)
        XCTAssertEqual(handler.currentItem?.playableId, "0")
        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "1")
        XCTAssertEqual(handler.queueGeneration, 1)
    }

    func testWindowItems() {
        let handler = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 4)
        let window = handler.windowItems(previous: 2, next: 5)
        XCTAssertEqual(window.map(\.playableId), ["2", "3", "4", "5", "6", "7", "8", "9"])
    }

    func testRetreatWrapsWhenRepeatAll() {
        let handler = PlayQueueHandler()
        let items = (0..<3).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 0)
        handler.setRepeat(.all)

        XCTAssertEqual(handler.currentItem?.playableId, "0")
        _ = handler.retreat()
        XCTAssertEqual(handler.currentItem?.playableId, "2")
        _ = handler.retreat()
        XCTAssertEqual(handler.currentItem?.playableId, "1")
    }

    func testRetreatDoesNotWrapWhenRepeatOff() {
        let handler = PlayQueueHandler()
        let items = (0..<3).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 0)
        handler.setRepeat(.off)

        XCTAssertEqual(handler.currentItem?.playableId, "0")
        _ = handler.retreat()
        XCTAssertEqual(handler.currentItem?.playableId, "0")
    }

    func testToggleShuffleLeadsWithPlayingTrackAndKeepsWholeContext() {
        let handler = PlayQueueHandler()
        let items = (0..<40).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 30)

        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .on)
        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.currentItem?.playableId, "30")
        XCTAssertEqual(Set(handler.activeQueue.map(\.playableId)), Set(items.map(\.playableId)))
        XCTAssertNotEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))
    }

    /// Queueing can insert a second copy of a song already in the context. Shuffle must
    /// keep the *playing* row, not the first id match.
    func testToggleShufflePrefersPlayingRowWhenIdsDuplicate() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 2) // playing "2"
        handler.enqueueNext([QueueItem(playableId: "2", title: "Song 2 queued")])
        // Queue is [0, 1, 2, 2(user)]; still playing the context copy at index 2.
        XCTAssertEqual(handler.currentIndex, 2)
        XCTAssertFalse(handler.activeQueue[2].isUserQueued)

        handler.toggleShuffle()

        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.currentItem?.playableId, "2")
        XCTAssertFalse(handler.currentItem?.isUserQueued == true)
        XCTAssertEqual(handler.activeQueue.filter { $0.playableId == "2" }.count, 2)
    }

    func testTogglingShuffleOffRestoresOriginalOrderAndIndex() {
        let handler = PlayQueueHandler()
        let items = (0..<40).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 12)

        handler.toggleShuffle()
        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .off)
        XCTAssertEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))
        XCTAssertEqual(handler.currentItem?.playableId, "12")
    }

    /// A context started in shuffle mode must remember the order it arrived in, so the
    /// button can un-shuffle back to it.
    func testShuffledContextUnshufflesToIncomingOrder() {
        let handler = PlayQueueHandler()
        let items = (0..<40).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.setShuffle(.on, reorder: false)
        handler.replaceContext(with: items, startAt: 7)

        XCTAssertNotEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))

        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .off)
        XCTAssertEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))
        XCTAssertEqual(handler.currentItem?.playableId, "7")
    }

    func testMoveFromAbovePlayingTrackKeepsPointerOnIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet(integer: 1), to: 9)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "2", "3", "4", "5", "6", "7", "8", "1", "9"])
        XCTAssertEqual(handler.currentIndex, 4)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testMoveFromBelowPlayingTrackKeepsPointerOnIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet(integer: 8), to: 0)

        XCTAssertEqual(handler.currentIndex, 6)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testMovingThePlayingTrackFollowsIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet(integer: 5), to: 0)

        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testMultiRowMoveLandsContiguously() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet([0, 1]), to: 10)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["2", "3", "4", "5", "6", "7", "8", "9", "0", "1"])
        XCTAssertEqual(handler.currentIndex, 3)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testEnqueueMarksItemsAsUserQueued() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)

        handler.enqueueNext([QueueItem(playableId: "next", title: "Next")])
        handler.enqueueLast([QueueItem(playableId: "last", title: "Last")])

        XCTAssertEqual(handler.activeQueue.filter(\.isUserQueued).map(\.playableId), ["next", "last"])
        XCTAssertFalse(handler.activeQueue[0].isUserQueued)
    }

    func testEphemeralItemsQueueAfterCurrentTrackInAddedOrder() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)

        handler.enqueueEphemeral([QueueItem(playableId: "first", title: "First")])
        handler.enqueueEphemeral([QueueItem(playableId: "second", title: "Second")])

        XCTAssertEqual(
            handler.activeQueue.map(\.playableId),
            ["0", "first", "second", "1", "2"],
            "a second temporary add must land behind the first, not ahead of it"
        )
        XCTAssertTrue(handler.activeQueue[1].isEphemeral)
        XCTAssertTrue(handler.activeQueue[1].isUserQueued)
    }

    func testEphemeralItemLeavesQueueOncePlayed() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "temp", title: "Temp")])

        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "temp")
        XCTAssertEqual(handler.activeQueue.count, 4)

        _ = handler.advance()

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2"])
        XCTAssertEqual(handler.currentItem?.playableId, "1", "the playhead must stay on the track it moved to")
    }

    func testEphemeralRemovalKeepsTheContextCopyOfTheSameSong() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "2", title: "Song 2")])

        _ = handler.advance()
        _ = handler.advance()

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2"])
    }

    func testJumpingAwayDropsTheEphemeralItemLeftBehind() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(4), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "temp", title: "Temp")])
        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "temp")

        handler.jump(to: 3)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2", "3"])
        XCTAssertEqual(handler.currentItem?.playableId, "2", "the jump target follows the removal")
    }

    /// Jumping into Next Up would leave the queued run stranded after the old playhead.
    /// It has to travel with the jump so "Added to Queue" stays next up.
    func testJumpingPastUserQueuedMovesTheRunAfterTheNewCurrent() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 0)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        // [0, a, b, 1, 2, 3, 4] — jump to "3" at index 5.
        handler.jump(to: 5)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2", "3", "a", "b", "4"])
        XCTAssertEqual(handler.currentItem?.playableId, "3")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["a", "b"])
    }

    /// Same idea going backwards: the section follows the playhead, it doesn't stay parked
    /// ahead of songs the user already skipped back over.
    func testJumpingBackMovesUserQueuedAfterTheNewCurrent() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 2)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        // [0, 1, 2, a, b, 3, 4] — jump back to "0".
        handler.jump(to: 0)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "a", "b", "1", "2", "3", "4"])
        XCTAssertEqual(handler.currentItem?.playableId, "0")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["a", "b"])
    }

    /// Relocating slides rows under the old playhead index; the departed ephemeral must
    /// still be the one that leaves, not a queued neighbour that landed on that index.
    func testJumpingBackFromEphemeralDropsItAndMovesTheRest() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        _ = handler.advance() // playing "a"; run after playhead is ["b"]

        handler.jump(to: 0)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "b", "1", "2"])
        XCTAssertEqual(handler.currentItem?.playableId, "0")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["b"])
    }

    func testJumpingIntoUserQueuedDoesNotRelocateTheRun() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])

        handler.jump(to: 2) // "b"

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "a", "b", "1", "2"])
        XCTAssertEqual(handler.currentItem?.playableId, "b")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), [])
    }

    /// Leaving an ephemeral track still drops it; the rest of the run follows the jump.
    func testJumpingPastUserQueuedFromAnEphemeralDropsItAndMovesTheRest() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        _ = handler.advance() // playing "a"; run after playhead is ["b"]

        handler.jump(to: 4) // "2"

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2", "b"])
        XCTAssertEqual(handler.currentItem?.playableId, "2")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["b"])
    }

    /// Stepping back off an "Added to Queue" track is leaving it the same as skipping
    /// forward would — the listen is done, so it must not reappear in that section.
    func testGoingBackDropsTheEphemeralItem() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "temp", title: "Temp")])
        _ = handler.advance()

        _ = handler.retreat()

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2"])
        XCTAssertEqual(handler.currentItem?.playableId, "0")
        XCTAssertTrue(handler.userQueuedItems.isEmpty)
    }

    /// Only the track the playhead left is done; anything still waiting in Added to Queue
    /// stays next up after the song the user stepped back to.
    func testGoingBackFromEphemeralKeepsTheRestOfTheRun() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        _ = handler.advance() // playing "a"

        _ = handler.retreat()

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "b", "1", "2"])
        XCTAssertEqual(handler.currentItem?.playableId, "0")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["b"])
    }

    func testEphemeralAtTheEndIsDroppedWhenRepeatAllWrapsAround() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(2), startAt: 0)
        handler.setRepeat(.all)
        _ = handler.advance()
        // Queued from the last track, so it sits at the end: 0, 1, temp.
        handler.enqueueEphemeral([QueueItem(playableId: "temp", title: "Temp")])

        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "temp")
        _ = handler.advance()

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1"])
        XCTAssertEqual(handler.currentItem?.playableId, "0", "wrapping to the front is unaffected by the drop")
    }

    func testRemoveOnlyTakesUserQueuedRows() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 0)
        handler.enqueueNext([QueueItem(playableId: "queued", title: "Queued")])

        handler.remove(at: IndexSet(integer: 2))
        XCTAssertEqual(handler.activeQueue.count, 6, "context rows must not be removable")

        handler.remove(at: IndexSet(integer: 1))
        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2", "3", "4"])
    }

    func testRemovingRowAbovePlayingTrackKeepsPointerOnIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 0)
        handler.enqueueNext([QueueItem(playableId: "queued", title: "Queued")])
        _ = handler.advance()
        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "1")

        handler.remove(at: IndexSet(integer: 1))

        XCTAssertEqual(handler.currentIndex, 1)
        XCTAssertEqual(handler.currentItem?.playableId, "1")
    }

    /// Top-ups extend the context itself. Marking them user-queued would make the rows
    /// removable and turn every shuffled track into a user-queued entry.
    func testAppendContextAddsContextRowsNotUserQueuedOnes() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)

        handler.appendContext([QueueItem(playableId: "extra", title: "Extra")])

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2", "extra"])
        XCTAssertTrue(handler.activeQueue.allSatisfy { !$0.isUserQueued })
    }

    /// Prefetch treats a newer generation as a signal that the old queue's cached files
    /// are obsolete, so extending a context must not look like starting one.
    func testAppendContextDoesNotBumpGenerations() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        let queueGeneration = handler.queueGeneration
        let contextGeneration = handler.contextGeneration

        handler.appendContext([QueueItem(playableId: "extra", title: "Extra")])

        XCTAssertEqual(handler.queueGeneration, queueGeneration)
        XCTAssertEqual(handler.contextGeneration, contextGeneration)
    }

    /// `queueGeneration` can't answer "did the user play something else" — shuffling
    /// bumps it too. That's the whole reason `contextGeneration` exists.
    func testContextGenerationChangesOnlyForANewContext() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        let generation = handler.contextGeneration
        let queueGeneration = handler.queueGeneration

        handler.toggleShuffle()
        XCTAssertGreaterThan(handler.queueGeneration, queueGeneration)
        XCTAssertEqual(handler.contextGeneration, generation)

        handler.replaceContext(with: Self.songs(2), startAt: 0)
        XCTAssertEqual(handler.contextGeneration, generation + 1)
    }

    /// An open-ended context tops itself up for as long as playback runs, so played rows
    /// have to fall off the front or the queue grows all session.
    func testAppendContextTrimsPlayedHistoryAndFollowsThePlayingTrack() {
        let handler = PlayQueueHandler()
        let total = PlayQueueHandler.maxPlayedHistory + 30
        handler.replaceContext(with: Self.songs(total), startAt: total - 1)
        let playing = handler.currentItem?.playableId

        handler.appendContext([QueueItem(playableId: "extra", title: "Extra")])

        // Kept history, the playing track, and the track just appended.
        XCTAssertEqual(handler.activeQueue.count, PlayQueueHandler.maxPlayedHistory + 2)
        XCTAssertEqual(handler.currentIndex, PlayQueueHandler.maxPlayedHistory)
        XCTAssertEqual(handler.currentItem?.playableId, playing)
        XCTAssertEqual(handler.activeQueue.last?.playableId, "extra")
    }

    func testAppendContextLeavesAShortQueueIntact() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 4)

        handler.appendContext([QueueItem(playableId: "extra", title: "Extra")])

        XCTAssertEqual(handler.activeQueue.count, 6)
        XCTAssertEqual(handler.currentIndex, 4)
        XCTAssertEqual(handler.currentItem?.playableId, "4")
    }

    /// Trimming drops rows from the shuffled queue; the restore-order copy has to lose
    /// them too, or turning shuffle off would resurrect tracks that already played.
    func testTrimmedRowsDoNotComeBackWhenShuffleIsTurnedOff() {
        let handler = PlayQueueHandler()
        let total = PlayQueueHandler.maxPlayedHistory + 30
        handler.replaceContext(with: Self.songs(total), startAt: 0)
        handler.toggleShuffle()
        for _ in 0..<(total - 1) { _ = handler.advance() }

        handler.appendContext([QueueItem(playableId: "extra", title: "Extra")])
        let trimmedCount = handler.activeQueue.count
        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .off)
        XCTAssertEqual(handler.activeQueue.count, trimmedCount)
    }

    // MARK: - The user-queued section

    func testUserQueuedRangeCoversTheRunAfterThePlayingTrack() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        XCTAssertTrue(handler.userQueuedRange.isEmpty, "a plain context has nothing the user queued")

        handler.enqueueEphemeral([QueueItem(playableId: "a", title: "A")])
        handler.enqueueEphemeral([QueueItem(playableId: "b", title: "B")])

        XCTAssertEqual(handler.userQueuedRange, 1..<3)
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["a", "b"])
    }

    /// The run belongs to the playhead, not to the queue as a whole: once playback moves
    /// into it, the rows already played are part of the past, not of what was queued.
    func testUserQueuedRangeShrinksAsPlaybackMovesIntoIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueNext([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])

        _ = handler.advance()

        XCTAssertEqual(handler.currentItem?.playableId, "a")
        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["b"])
    }

    /// `enqueueLast` drops a queued row at the very end, where it plays as part of the
    /// context around it. Listing it with the queued run would claim an order the queue
    /// does not have.
    func testUserQueuedRangeStopsAtTheFirstContextRow() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueNext([QueueItem(playableId: "next", title: "Next")])
        handler.enqueueLast([QueueItem(playableId: "last", title: "Last")])

        XCTAssertEqual(handler.userQueuedItems.map(\.playableId), ["next"])
    }

    func testMoveUserQueuedReordersWithinTheSection() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "a", title: "A")])
        handler.enqueueEphemeral([QueueItem(playableId: "b", title: "B")])

        handler.moveUserQueued(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "b", "a", "1", "2"])
        XCTAssertEqual(handler.currentItem?.playableId, "0")
    }

    /// The section's own index space is all the queue screen hands over, so a drag can
    /// neither reach into the context nor push a row ahead of the playing track.
    func testMoveUserQueuedStaysInsideTheSection() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "a", title: "A")])
        handler.enqueueEphemeral([QueueItem(playableId: "b", title: "B")])

        handler.moveUserQueued(from: IndexSet(integer: 0), to: 99)
        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "b", "a", "1", "2"])

        handler.moveUserQueued(from: IndexSet(integer: 7), to: 0)
        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "b", "a", "1", "2"])
        XCTAssertEqual(handler.userQueuedRange, 1..<3)
    }

    /// Removal is positional for a reason: the queued copy and the context copy of the
    /// same song share an id, and taking the wrong one would edit the album.
    func testRemoveUserQueuedTakesTheQueuedCopyNotTheContextOne() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "2", title: "Song 2")])

        handler.removeUserQueued(at: IndexSet(integer: 0))

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2"])
        XCTAssertTrue(handler.activeQueue.allSatisfy { !$0.isUserQueued })
        XCTAssertEqual(handler.currentIndex, 0)
    }

    func testRemoveUserQueuedIgnoresOffsetsOutsideTheSection() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        handler.enqueueEphemeral([QueueItem(playableId: "a", title: "A")])

        handler.removeUserQueued(at: IndexSet(integer: 2))

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "a", "1", "2"])
    }

    /// Editing the queued section is offered without shuffle, so it has to work with the
    /// context in its original order too.
    func testUserQueuedEditsWorkWithShuffleOff() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(4), startAt: 1)
        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        XCTAssertEqual(handler.shuffleMode, .off)

        handler.moveUserQueued(from: IndexSet(integer: 0), to: 2)
        handler.removeUserQueued(at: IndexSet(integer: 1))

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "b", "2", "3"])
        XCTAssertEqual(handler.currentItem?.playableId, "1")
    }

    // MARK: - Surviving a relaunch

    /// Stands in for closing and reopening the app: the same store, a handler that has
    /// never seen the queue.
    private func relaunch(with store: FilePlayerQueueStore) async -> PlayQueueHandler {
        let handler = PlayQueueHandler(persister: store)
        await handler.loadFromDisk()
        return handler
    }

    func testTheQueueComesBackWhereItLeftOff() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")

        let handler = PlayQueueHandler(persister: store)
        handler.replaceContext(with: Self.songs(5), startAt: 2)
        handler.setRepeat(.all)
        handler.updatePlaybackPosition(42)
        await awaitStoredQueue(in: store) { $0?.playbackPosition == 42 }

        let relaunched = await relaunch(with: store)

        XCTAssertEqual(relaunched.activeQueue.map(\.playableId), ["0", "1", "2", "3", "4"])
        XCTAssertEqual(relaunched.currentItem?.playableId, "2")
        XCTAssertEqual(relaunched.repeatMode, .all)
        XCTAssertEqual(relaunched.playbackPosition, 42)
    }

    /// Shuffle keeps a copy of the order the context arrived in. Without it in the stored
    /// queue, turning shuffle off after a relaunch would freeze the shuffled order.
    func testShuffleCanStillBeTurnedOffAfterARelaunch() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")

        let handler = PlayQueueHandler(persister: store)
        handler.replaceContext(with: Self.songs(10), startAt: 0)
        handler.toggleShuffle()
        await awaitStoredQueue(in: store) { $0?.shuffleMode == .on }

        let relaunched = await relaunch(with: store)
        XCTAssertEqual(relaunched.shuffleMode, .on)
        relaunched.toggleShuffle()

        XCTAssertEqual(
            relaunched.activeQueue.map(\.playableId),
            ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        )
    }

    /// "Add to Queue" lives in its own file and is spliced back after the playhead, so a
    /// relaunch still shows the Added to Queue section without having rewritten the album.
    func testAddedToQueueSurvivesARelaunch() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")

        let handler = PlayQueueHandler(persister: store)
        handler.replaceContext(with: Self.songs(3), startAt: 0)
        await awaitStoredQueue(in: store) { $0?.context.count == 3 }

        handler.enqueueEphemeral([
            QueueItem(playableId: "a", title: "A"),
            QueueItem(playableId: "b", title: "B")
        ])
        await awaitStoredUserQueue(in: store) { $0.map(\.playableId) == ["a", "b"] }

        // Adding to the queue must not rewrite the context album / playlist.
        let contextAfterEnqueue = await store.loadQueue()
        XCTAssertEqual(contextAfterEnqueue?.context.map(\.playableId), ["0", "1", "2"])
        XCTAssertEqual(contextAfterEnqueue?.index, 0)

        let relaunched = await relaunch(with: store)

        XCTAssertEqual(relaunched.activeQueue.map(\.playableId), ["0", "a", "b", "1", "2"])
        XCTAssertEqual(relaunched.currentItem?.playableId, "0")
        XCTAssertEqual(relaunched.userQueuedItems.map(\.playableId), ["a", "b"])
        XCTAssertTrue(relaunched.userQueuedItems.allSatisfy(\.isEphemeral))
    }

    /// An older build that still embedded the Added-to-Queue run inside the context file
    /// should peel it out and present the same merged queue.
    func testLegacyEmbeddedUserQueueIsMergedOnLoad() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        let stored = [
            QueueItem(playableId: "0", title: "Song 0"),
            QueueItem(playableId: "temp", title: "Temporary", isUserQueued: true, isEphemeral: true),
            QueueItem(playableId: "1", title: "Song 1")
        ]
        await store.saveQueue(PersistedPlayerQueue(context: stored, index: 0))

        let relaunched = await relaunch(with: store)

        XCTAssertEqual(relaunched.activeQueue.map(\.playableId), ["0", "temp", "1"])
        XCTAssertEqual(relaunched.userQueuedItems.map(\.playableId), ["temp"])
    }

    /// One-listen rows that are not the playing track and not in Added to Queue (an older
    /// snapshot that left one behind the playhead) are dropped so they can't resurrect.
    func testStaleEphemeralRowsBehindThePlayheadAreDropped() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        let stored = [
            QueueItem(playableId: "0", title: "Song 0"),
            QueueItem(playableId: "temp", title: "Temporary", isUserQueued: true, isEphemeral: true),
            QueueItem(playableId: "1", title: "Song 1")
        ]
        await store.saveQueue(PersistedPlayerQueue(context: stored, index: 2))

        let relaunched = await relaunch(with: store)

        XCTAssertEqual(relaunched.activeQueue.map(\.playableId), ["0", "1"])
        XCTAssertEqual(relaunched.currentItem?.playableId, "1")
    }

    func testClearingEmptiesTheQueueAndForgetsTheStoredOne() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")

        let handler = PlayQueueHandler(persister: store)
        handler.replaceContext(with: Self.songs(3), startAt: 1)
        handler.updatePlaybackPosition(30)
        await awaitStoredQueue(in: store) { $0?.playbackPosition == 30 }

        handler.clear()

        XCTAssertTrue(handler.activeQueue.isEmpty)
        XCTAssertNil(handler.currentItem)
        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.playbackPosition, 0)
        await awaitStoredQueue(in: store) { $0 == nil }
        let relaunched = await relaunch(with: store)
        XCTAssertTrue(relaunched.activeQueue.isEmpty)
    }

    /// Switching accounts empties the player without discarding the queue of the account
    /// being left — it should still be there when the user comes back to it.
    func testClearingForAnAccountSwitchKeepsTheStoredQueue() async {
        let directory = URL.temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")

        let handler = PlayQueueHandler(persister: store)
        handler.replaceContext(with: Self.songs(3), startAt: 1)
        await awaitStoredQueue(in: store) { $0?.context.count == 3 }

        handler.clear(forgetStored: false)

        XCTAssertTrue(handler.activeQueue.isEmpty)
        let relaunched = await relaunch(with: store)
        XCTAssertEqual(relaunched.activeQueue.map(\.playableId), ["0", "1", "2"])
        XCTAssertEqual(relaunched.currentIndex, 1)
    }

    func testUnshufflingKeepsQueueEditsMadeWhileShuffled() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 0)
        handler.toggleShuffle()

        handler.enqueueLast([
            QueueItem(playableId: "kept", title: "Kept"),
            QueueItem(playableId: "dropped", title: "Dropped")
        ])
        let removeAt = handler.activeQueue.firstIndex { $0.playableId == "dropped" }!
        handler.remove(at: IndexSet(integer: removeAt))

        handler.toggleShuffle()

        let ids = handler.activeQueue.map(\.playableId)
        XCTAssertEqual(ids, ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "kept"])
    }
}
