import CarPlay
import Combine
import MediaPlayer
import UIKit
import VerodromeKit
import os

/// Xcode's console often hides `os.Logger` from a second scene unless you filter by
/// category. `print` / `NSLog` always show next to PlayTrace when the debugger is attached.
enum CarPlayLog {
    private static let logger = Logger(subsystem: "com.verodrome", category: "CarPlay")

    static func notice(_ message: String) {
        print("🚗 CARPLAY \(message)")
        NSLog("🚗 CARPLAY %@", message)
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        print("🚗 CARPLAY ERROR \(message)")
        NSLog("🚗 CARPLAY ERROR %@", message)
        logger.error("\(message, privacy: .public)")
    }
}

/// CarPlay's ObjC selectors are `didConnectInterfaceController:` / `didDisconnectInterfaceController:`.
/// The 3-argument window variants are renamed to `didConnect:to:` / `didDisconnect:from:`.
/// Implementing only `didConnect` leaves the scene with no root template; tapping the dock
/// icon while Now Playing is visible then throws and kills the app.
@available(iOS 14.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?
    private let catalog = CarPlayCatalog()
    private var cancellables = Set<AnyCancellable>()
    private var tabBar: CPTabBarTemplate?
    private var homeTab: CPListTemplate?
    private var recentsTab: CPListTemplate?
    private var searchTab: CPListTemplate?
    private var libraryTab: CPListTemplate?
    private var isConnected = false
    /// Pushing `CPNowPlayingTemplate.shared` twice is rejected, so serialize attempts.
    private var isPresentingNowPlaying = false
    /// Recents are recorded immediately, but Home is only redrawn when it is on screen
    /// so an in-place section update cannot pop Now Playing.
    private var pendingHomeRefresh = false
    /// Shuffle / repeat selected state is reported via `MPRemoteCommandCenter`, not by
    /// replacing the buttons. Rebuilding the row on every tap is the blink.
    private var nowPlayingButtonLayout: NowPlayingButtonLayout?

    /// Audio apps may stack at most 5 templates; pushing past that is rejected.
    private static let templateDepthLimit = 5

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        CarPlayLog.notice(
            "scene willConnect | role=\(session.role.rawValue) type=\(String(describing: type(of: scene)))"
        )
        guard let scene = scene as? CPTemplateApplicationScene else {
            CarPlayLog.error("willConnect skipped: scene is not CPTemplateApplicationScene")
            return
        }
        handleConnect(scene.interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayLog.notice("didConnectInterfaceController")
        handleConnect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayLog.notice("didConnect")
        handleConnect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        CarPlayLog.notice("didConnect:to window")
        handleConnect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        handleDisconnect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        handleDisconnect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        handleDisconnect()
    }

    private func handleConnect(_ interfaceController: CPInterfaceController) {
        CarPlayLog.notice(
            "scene connected | alreadyConnected=\(self.isConnected) maximumTabCount=\(CPTabBarTemplate.maximumTabCount)"
        )
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        catalog.interfaceController = interfaceController
        catalog.onDidStartPlayback = { [weak self] in
            self?.presentNowPlaying()
        }
        catalog.onOpenSearch = { [weak self] in
            self?.showSearchTab()
        }
        catalog.onSearchQuery = { [weak self] query in
            Task { @MainActor in
                await self?.showSearchResults(query)
            }
        }
        catalog.onOpenNowPlaying = { [weak self] in
            self?.presentNowPlaying()
        }
        CarPlayConnection.isActive = true
        CarPlayVoiceSearch.receiver = { [weak self] query in
            Task { @MainActor in
                await self?.handleVoiceSearch(query)
            }
        }
        configureNowPlaying()
        installRootIfNeeded(interfaceController)

        let alreadyConnected = isConnected
        isConnected = true
        if alreadyConnected {
            presentNowPlayingIfAudioIsPlaying()
            drainPendingVoiceSearch()
            return
        }

        Task { @MainActor in
            await VerodromeKit.shared.initialize()
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()
            observePlayer()
            refreshNowPlayingButtons()
            VerodromeKit.shared.player?.syncPublishedState()
            resumePausedQueueOnConnect()
            presentNowPlayingIfQueueActive()
            if let homeTab, let recentsTab, !isNowPlayingInStack {
                homeTab.updateSections(catalog.makeHomeSectionsFromCache())
                recentsTab.updateSections(catalog.recentsSections())
            }
            CarPlayArtworkWarmer.shared.start(catalog: catalog) { [weak self] in
                await self?.refreshHomeTab()
            }
            drainPendingVoiceSearch()
        }
    }

    /// A voice search that arrived before this scene was ready is replayed here, once
    /// the library is initialized so the results are not built against an empty store.
    private func drainPendingVoiceSearch() {
        guard let pending = CarPlayVoiceSearch.takePending() else { return }
        CarPlayLog.notice("draining pending voice search \(pending)")
        Task { @MainActor in
            await handleVoiceSearch(pending)
        }
    }

    private func handleDisconnect() {
        CarPlayLog.notice("scene disconnected")
        CarPlayConnection.isActive = false
        CarPlayVoiceSearch.receiver = nil
        VerodromeKit.shared.player?.endIntervalHold()
        CarPlayArtworkWarmer.shared.stop()
        CPNowPlayingTemplate.shared.remove(self)
        interfaceController = nil
        catalog.interfaceController = nil
        catalog.onDidStartPlayback = nil
        catalog.onOpenSearch = nil
        catalog.onSearchQuery = nil
        catalog.onOpenNowPlaying = nil
        tabBar = nil
        homeTab = nil
        recentsTab = nil
        searchTab = nil
        libraryTab = nil
        isConnected = false
        isPresentingNowPlaying = false
        pendingHomeRefresh = false
        nowPlayingButtonLayout = nil
        cancellables.removeAll()
    }

    /// CarPlay requires a root template before `didConnect` returns. Artwork is
    /// filled in afterward by updating the existing list sections — replacing the
    /// tab bar with `updateTemplates` pops any pushed Now Playing screen.
    private func installRootIfNeeded(_ interfaceController: CPInterfaceController) {
        if tabBar != nil { return }

        let home = catalog.makeHomeTemplateSync()
        let recents = catalog.makeRecentsTemplate()
        let search = catalog.makeSearchTabTemplate()
        let library = catalog.makeLibraryTemplate()
        homeTab = home
        recentsTab = recents
        searchTab = search
        libraryTab = library

        // Audio apps may only host list/grid templates in the tab bar.
        var tabs: [CPTemplate] = [home, recents, search, library]
        let maxTabs = CPTabBarTemplate.maximumTabCount
        if tabs.count > maxTabs {
            tabs = Array(tabs.prefix(maxTabs))
        }
        let bar = CPTabBarTemplate(templates: tabs)
        bar.delegate = self
        tabBar = bar
        CarPlayLog.notice("installing root tab bar | tabs=\(tabs.count) max=\(maxTabs)")
        // Completion is required: a failed presentation without one throws.
        interfaceController.setRootTemplate(bar, animated: false) { [weak self] success, error in
            Self.logIfFailed("setRootTemplate", success: success, error: error)
            guard success else { return }
            CarPlayLog.notice("setRootTemplate succeeded")
            Task { @MainActor in
                self?.presentNowPlayingIfAudioIsPlaying()
            }
        }
    }

    @MainActor
    private func refreshHomeTab() async {
        guard let homeTab, let recentsTab else { return }
        if isNowPlayingInStack {
            pendingHomeRefresh = true
            CarPlayLog.notice("deferring home refresh; Now Playing is in the stack")
            return
        }
        pendingHomeRefresh = false
        CarPlayLog.notice("refreshing Home/Recents sections in place")
        homeTab.updateSections(await catalog.makeHomeSectionsLoaded())
        recentsTab.updateSections(catalog.recentsSections())
    }

    /// Apply a queued recents update now that Home (or Recents) is visible again.
    @MainActor
    private func refreshHomeIfPending() async {
        guard pendingHomeRefresh else { return }
        await refreshHomeTab()
    }

    private var isNowPlayingInStack: Bool {
        interfaceController?.templates.contains { $0 is CPNowPlayingTemplate } == true
    }

    // MARK: - Now Playing

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.remove(self)
        template.add(self)
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Queue"
        template.isAlbumArtistButtonEnabled = true
        if #available(iOS 18.4, *) {
            template.nowPlayingMode = .default
        }
        refreshNowPlayingButtons()
    }

    private func observePlayer() {
        cancellables.removeAll()
        if let player = VerodromeKit.shared.player {
            player.$currentItem
                .map { item in (item?.playableId, item?.kind == .song) }
                .removeDuplicates { $0 == $1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshNowPlayingButtons()
                    self?.catalog.refreshQueueIfPresented()
                }
                .store(in: &cancellables)
            player.$queueGeneration
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.catalog.refreshQueueIfPresented()
                }
                .store(in: &cancellables)
        }

        PlaylistMembershipIndex.shared.$version
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshNowPlayingButtons()
                self?.catalog.refreshPlaylistMembershipIfPresented()
            }
            .store(in: &cancellables)

        RecentQueueStore.shared.$entries
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pendingHomeRefresh = true
                Task { await self?.refreshHomeIfPending() }
            }
            .store(in: &cancellables)
    }

    private func refreshNowPlayingButtons() {
        let layout = NowPlayingButtonLayout(
            showPlaylist: isCurrentItemSong,
            inPlaylist: isCurrentSongInAnyPlaylist,
            showShuffle: VerodromeKit.shared.player?.canShuffleQueue == true
        )
        guard layout != nowPlayingButtonLayout else { return }
        nowPlayingButtonLayout = layout

        var buttons: [CPNowPlayingButton] = []
        if layout.showPlaylist {
            let add = CPNowPlayingImageButton(
                image: CarPlayArtwork.nowPlayingPlaylistSymbol(isInPlaylist: layout.inPlaylist)
            ) { [weak self] _ in
                self?.catalog.pushPlaylistMembership()
            }
            buttons.append(add)
        }
        if layout.showShuffle {
            // Handler (not the no-arg initializer): CarPlay does not reliably send
            // `changeShuffleModeCommand` for third-party audio apps. Selected state
            // still comes from `currentShuffleType` — do not rebuild this row on tap.
            buttons.append(CPNowPlayingShuffleButton { [weak self] _ in
                VerodromeKit.shared.player?.toggleShuffle()
                self?.catalog.refreshQueueIfPresented()
            })
        }
        buttons.append(CPNowPlayingRepeatButton { [weak self] _ in
            VerodromeKit.shared.player?.toggleRepeat()
        })
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    private struct NowPlayingButtonLayout: Equatable {
        var showPlaylist: Bool
        var inPlaylist: Bool
        var showShuffle: Bool
    }

    private var isCurrentItemSong: Bool {
        VerodromeKit.shared.player?.currentItem?.kind == .song
    }

    private var isCurrentSongInAnyPlaylist: Bool {
        guard let playableId = VerodromeKit.shared.player?.currentItem?.playableId,
              isCurrentItemSong else { return false }
        return PlaylistMembershipIndex.shared.isInAnyPlaylist(songId: playableId)
    }

    private func showSearchTab() {
        guard let tabBar, let searchTab else { return }
        if #available(iOS 17.0, *) {
            tabBar.select(searchTab)
        }
    }

    private func refreshSearchRecents() {
        searchTab?.updateSections(catalog.searchRecentsSections())
    }

    /// The term is already recorded by `CarPlayVoiceSearch.submit`, so this only has to
    /// put the results on screen. Recents live on the Search tab underneath the
    /// pushed list and are stale until `updateSections` runs.
    private func handleVoiceSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        CarPlayLog.notice("voice search \(trimmed)")
        // Results replace whatever was on screen rather than stacking on top of it,
        // which also keeps the push clear of the 5-template depth limit.
        await popToRoot()
        showSearchTab()
        refreshSearchRecents()
        if await showSearchResults(trimmed) { return }

        // A push can still be refused, so fall back to the Search tab itself, where no
        // presentation can be rejected. Recents stay below the results.
        CarPlayLog.notice("voice search \(trimmed) falling back to in-place results")
        guard let searchTab else { return }
        let sections = await catalog.searchResultSections(query: trimmed)
        searchTab.updateSections(sections + catalog.searchRecentsSections())
    }

    private func popToRoot() async {
        guard let interfaceController, interfaceController.templates.count > 1 else { return }
        await withCheckedContinuation { continuation in
            interfaceController.popToRootTemplate(animated: false) { success, error in
                if !success {
                    CarPlayLog.error(
                        "popToRoot failed: \(error?.localizedDescription ?? "unknown error")"
                    )
                }
                continuation.resume()
            }
        }
    }

    /// iOS 26 audio CarPlay rejects `CPSearchTemplate` on `pushTemplate` (crash).
    /// A recent term opens a pushed Artists / Albums / Songs list instead.
    @discardableResult
    private func showSearchResults(_ query: String) async -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showSearchTab()
            return false
        }
        CarPlayLog.notice("showSearchResults(\(trimmed))")
        return await catalog.pushSearchResults(query: trimmed)
    }

    /// When CarPlay connects while Verodrome is already playing, land on Now Playing
    /// instead of Home. The system may also launch this scene for the Now Playing
    /// widget; the shared template must already be configured (see `configureNowPlaying`).
    private func resumePausedQueueOnConnect() {
        guard let player = VerodromeKit.shared.player else { return }
        guard player.resumeIfPausedWithQueue() else { return }
        CarPlayLog.notice("paused queue on connect — resuming")
    }

    private func presentNowPlayingIfQueueActive() {
        let player = VerodromeKit.shared.player
        guard player.map({ !$0.queue.isEmpty && $0.currentItem != nil }) == true else {
            presentNowPlayingIfAudioIsPlaying()
            return
        }
        CarPlayLog.notice("active queue on connect — presenting Now Playing")
        presentNowPlaying()
    }

    private func presentNowPlayingIfAudioIsPlaying() {
        let player = VerodromeKit.shared.player
        let infoPlaying = MPNowPlayingInfoCenter.default().playbackState == .playing
        let rate = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? 0
        let isPlaying = player?.isPlaying == true || infoPlaying || rate > 0
        guard isPlaying else { return }
        CarPlayLog.notice("audio is playing on connect — presenting Now Playing")
        presentNowPlaying()
    }

    private func presentNowPlaying() {
        guard let interfaceController else {
            CarPlayLog.error("presentNowPlaying dropped: no interface controller")
            return
        }
        VerodromeKit.shared.player?.syncPublishedState()

        let nowPlaying = CPNowPlayingTemplate.shared
        let stack = interfaceController.templates
        CarPlayLog.notice(
            "presentNowPlaying | depth=\(stack.count) topIsNowPlaying=\(stack.last === nowPlaying) inStack=\(stack.contains { $0 === nowPlaying })"
        )
        if stack.last === nowPlaying { return }

        // Reading `templates` is an IPC round trip, so two taps in quick succession can
        // both see a stack without Now Playing and both try to push it. The second push
        // is then rejected outright.
        guard !isPresentingNowPlaying else {
            CarPlayLog.notice("presentNowPlaying skipped: a push is already in flight")
            return
        }

        // CarPlay refuses to push a template instance that is already in the stack.
        // That is the normal state whenever Queue or the album list sits on top of
        // Now Playing, so walk back down to it instead of pushing a duplicate.
        if stack.contains(where: { $0 === nowPlaying }) {
            popToNowPlaying()
            return
        }

        guard stack.count < Self.templateDepthLimit else {
            interfaceController.popToRootTemplate(animated: false) { [weak self] success, error in
                Self.logIfFailed("popToRootTemplate", success: success, error: error)
                Task { @MainActor in self?.pushNowPlaying() }
            }
            return
        }
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        guard let interfaceController else { return }
        isPresentingNowPlaying = true
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { [weak self] success, error in
            Task { @MainActor in
                self?.isPresentingNowPlaying = false
                guard !success else {
                    VerodromeKit.shared.player?.syncPublishedState()
                    return
                }
                Self.logIfFailed("pushTemplate(NowPlaying)", success: success, error: error)
                // CarPlay's own bookkeeping outranks our `templates` snapshot: if it says
                // the instance is already pushed, the screen we want is down the stack.
                self?.popToNowPlaying()
            }
        }
    }

    /// Terminal on purpose — never re-push from here, or a genuine rejection loops.
    private func popToNowPlaying() {
        guard let interfaceController else { return }
        interfaceController.pop(to: CPNowPlayingTemplate.shared, animated: true) { success, error in
            Self.logIfFailed("pop(to: NowPlaying)", success: success, error: error)
            if success {
                Task { @MainActor in
                    VerodromeKit.shared.player?.syncPublishedState()
                }
            }
        }
    }

    private static func logIfFailed(_ operation: String, success: Bool, error: Error?) {
        guard !success else { return }
        CarPlayLog.error("\(operation) failed: \(error?.localizedDescription ?? "unknown error")")
    }
}

@available(iOS 14.0, *)
extension CarPlaySceneDelegate: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        CarPlayLog.notice("tab selected | \(String(describing: type(of: selectedTemplate)))")
        if selectedTemplate === homeTab || selectedTemplate === recentsTab {
            Task { await refreshHomeIfPending() }
        }
        if selectedTemplate === searchTab {
            refreshSearchRecents()
        }
    }
}

/// Reports what CarPlay actually put on screen, which is the only way to tell a
/// rejected template apart from one that was accepted but drew empty.
@available(iOS 14.0, *)
extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        CarPlayLog.notice("templateDidAppear | \(String(describing: type(of: aTemplate)))")
        if aTemplate === homeTab || aTemplate === recentsTab || aTemplate is CPTabBarTemplate {
            Task { await refreshHomeIfPending() }
        }
        if aTemplate === searchTab {
            refreshSearchRecents()
        }
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        CarPlayLog.notice("templateDidDisappear | \(String(describing: type(of: aTemplate)))")
        if aTemplate is CPNowPlayingTemplate {
            Task { await refreshHomeIfPending() }
        }
    }
}

@available(iOS 14.0, *)
extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        catalog.pushQueue()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        catalog.pushPlayingAlbumOrPlaylist()
    }
}
