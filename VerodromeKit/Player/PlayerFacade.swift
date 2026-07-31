import Foundation
import Combine
import UIKit

@MainActor
public protocol PlayerControlling: AnyObject {
    var isPlaying: Bool { get }
    var currentItem: QueueItem? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var queue: [QueueItem] { get }
    var currentIndex: Int { get }
    var repeatMode: RepeatMode { get set }
    var shuffleMode: ShuffleMode { get }
    func play(items: [QueueItem], startAt: Int) async
    func play()
    func pause()
    func togglePlayPause()
    func stop()
    func next()
    func previous()
    func seek(to: TimeInterval)
    func enqueueNext(_ items: [QueueItem])
    func enqueueLast(_ items: [QueueItem])
    func remove(at offsets: IndexSet)
    func move(from: IndexSet, to: Int)
    func jump(to index: Int)
    func toggleShuffle()
    func setRepeatMode(_ mode: RepeatMode)
}

@MainActor
public protocol PlayerFacade: PlayerControlling {}

@MainActor
public final class PlayerFacadeImpl: ObservableObject, PlayerFacade {
    private let audioPlayer: AudioPlayer
    private weak var nowPlayingHandler: NowPlayingInfoCenterHandler?
    private weak var artworkResolver: ArtworkResolver?
    private var cancellables = Set<AnyCancellable>()

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentItem: QueueItem?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var lyrics: String = ""
    /// Non-empty while playback is stalled, e.g. waiting for the network to come back.
    @Published public private(set) var statusMessage: String = ""

    public init(audioPlayer: AudioPlayer) {
        self.audioPlayer = audioPlayer
        audioPlayer.backend.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self else { return }
                self.isPlaying = playing
                // Rate-only update — never rebuild metadata (that flashes empty artwork).
                self.nowPlayingHandler?.updatePlaybackState(
                    isPlaying: playing,
                    elapsed: self.currentTime,
                    rate: self.audioPlayer.backend.playbackRate
                )
            }
            .store(in: &cancellables)
        audioPlayer.backend.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.currentTime = time
                // While rate ≠ 1×, refresh lock-screen elapsed so the scrubber
                // tracks the engine instead of drifting on extrapolated time.
                let rate = self.audioPlayer.backend.playbackRate
                guard rate != 1, self.isPlaying else { return }
                self.nowPlayingHandler?.updatePlaybackState(
                    isPlaying: true,
                    elapsed: time,
                    rate: rate
                )
            }
            .store(in: &cancellables)
        audioPlayer.backend.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)
        audioPlayer.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.currentItem = item
                self?.pushNowPlaying(reloadArtwork: true)
            }
            .store(in: &cancellables)
        audioPlayer.$lyrics
            .receive(on: DispatchQueue.main)
            .assign(to: &$lyrics)
        audioPlayer.$statusMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$statusMessage)
        refreshPublished()
    }

    public func attachNowPlaying(_ handler: NowPlayingInfoCenterHandler) {
        nowPlayingHandler = handler
        pushNowPlaying(reloadArtwork: true)
    }

    public func attachArtworkResolver(_ resolver: ArtworkResolver) {
        artworkResolver = resolver
    }

    public var queue: [QueueItem] { audioPlayer.queueHandler.activeQueue }
    public var currentIndex: Int { audioPlayer.queueHandler.currentIndex }
    public var repeatMode: RepeatMode {
        get { audioPlayer.queueHandler.repeatMode }
        set {
            audioPlayer.queueHandler.setRepeat(newValue)
            audioPlayer.applyRepeatMode(newValue)
        }
    }
    public var shuffleMode: ShuffleMode { audioPlayer.queueHandler.shuffleMode }

    public func play(items: [QueueItem], startAt: Int) async {
        PlayTrace.mark("PlayerFacade.play", details: "count=\(items.count) startAt=\(startAt)")
        await audioPlayer.play(items: items, startAt: startAt)
        PlayTrace.mark("PlayerFacade.play — audioPlayer returned; refreshPublished")
        refreshPublished()
        PlayTrace.mark("PlayerFacade.refreshPublished done")
    }

    public func play() {
        if !isPlaying {
            audioPlayer.toggle()
            // isPlaying sink updates Now Playing rate; avoid a full metadata rebuild.
            isPlaying = audioPlayer.backend.isPlaying
        }
    }

    public func pause() {
        if isPlaying {
            audioPlayer.toggle()
            isPlaying = audioPlayer.backend.isPlaying
        }
    }

    public func replaceQueue(with items: [QueueItem], startAt: Int) {
        Task { await play(items: items, startAt: startAt) }
    }

    public func togglePlayPause() {
        audioPlayer.toggle()
        isPlaying = audioPlayer.backend.isPlaying
    }

    public func stop() {
        audioPlayer.stop()
        refreshPublished()
    }

    public func next() {
        audioPlayer.playNext()
        refreshPublished()
    }

    public func previous() {
        audioPlayer.playPrevious()
        refreshPublished()
    }

    public func seek(to seconds: TimeInterval) {
        audioPlayer.backend.seek(to: seconds)
        currentTime = seconds
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    /// Temporarily change engine rate (e.g. hold skip = 2× / hold previous = 0.5×).
    public func setPlaybackRate(_ rate: Float) {
        audioPlayer.backend.setRate(rate)
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    public func enqueueNext(_ items: [QueueItem]) { audioPlayer.queueHandler.enqueueNext(items) }
    public func enqueueLast(_ items: [QueueItem]) { audioPlayer.queueHandler.enqueueLast(items) }
    public func remove(at offsets: IndexSet) { audioPlayer.queueHandler.remove(at: offsets) }
    public func remove(at index: Int) { audioPlayer.queueHandler.remove(at: IndexSet(integer: index)) }
    public func move(from: IndexSet, to: Int) { audioPlayer.queueHandler.move(from: from, to: to) }
    public func jump(to index: Int) {
        audioPlayer.queueHandler.jump(to: index)
        Task { await audioPlayer.playCurrent(); refreshPublished() }
    }
    public func toggleShuffle() { audioPlayer.queueHandler.toggleShuffle() }
    public func setRepeatMode(_ mode: RepeatMode) {
        audioPlayer.queueHandler.setRepeat(mode)
        audioPlayer.applyRepeatMode(mode)
    }
    public func setShuffleMode(_ mode: ShuffleMode) {
        if audioPlayer.queueHandler.shuffleMode != mode {
            audioPlayer.queueHandler.toggleShuffle()
        }
    }

    public func setEqualizerBands(_ bands: [Float]) {
        audioPlayer.applyEqualizerBands(bands)
    }

    public func setEqualizerEnabled(_ enabled: Bool) {
        audioPlayer.setEqualizerEnabled(enabled)
    }

    private var lastArtworkLoadedItemId: String?

    private func refreshPublished() {
        isPlaying = audioPlayer.backend.isPlaying
        let previousId = currentItem?.id
        currentItem = audioPlayer.nowPlaying ?? audioPlayer.queueHandler.currentItem
        currentTime = audioPlayer.backend.currentTime
        duration = audioPlayer.backend.duration
        lyrics = audioPlayer.lyrics
        statusMessage = audioPlayer.statusMessage
        let trackChanged = currentItem?.id != previousId
        pushNowPlaying(reloadArtwork: trackChanged || lastArtworkLoadedItemId != currentItem?.id)
    }

    private func pushNowPlaying(reloadArtwork: Bool) {
        let rate = audioPlayer.backend.playbackRate
        nowPlayingHandler?.update(
            item: currentItem,
            isPlaying: isPlaying,
            elapsed: currentTime,
            duration: duration,
            rate: rate
        )
        guard reloadArtwork,
              let artworkId = currentItem?.artworkId,
              let resolver = artworkResolver
        else { return }

        let itemId = currentItem?.id
        Task {
            guard let image = await resolver.managerImage(for: artworkId) else { return }
            guard self.currentItem?.id == itemId else { return }
            self.lastArtworkLoadedItemId = itemId
            self.nowPlayingHandler?.update(
                item: self.currentItem,
                isPlaying: self.isPlaying,
                elapsed: self.currentTime,
                duration: self.duration,
                rate: self.audioPlayer.backend.playbackRate,
                artwork: image
            )
        }
    }
}

extension ArtworkResolver {
    public func managerImage(for token: String) async -> UIImage? {
        if let url = await resolvedURL(for: token, kind: .album, size: 1200) {
            if url.isFileURL {
                return UIImage(contentsOfFile: url.path)
            }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                return UIImage(data: data)
            }
        }
        return nil
    }
}
