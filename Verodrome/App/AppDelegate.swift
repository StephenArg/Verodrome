import AVFoundation
import CarPlay
import Intents
import MediaPlayer
import UIKit
import VerodromeKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        // Remote commands are bound in VerodromeKit.initialize once the player exists.
        // Do not register stub handlers here — duplicate targets break lock-screen play/pause.
        application.beginReceivingRemoteControlEvents()
        BackgroundLibrarySyncer.register()
        BackgroundLibrarySyncer.scheduleNext()
        observeCarPlayAudioRoute()
        requestSiriAuthorization()
        CarPlayLog.notice("AppDelegate didFinishLaunching")
        return true
    }

    /// Without this the app is never an authorized Siri target, so the CarPlay
    /// assistant cell fails instead of delivering `INPlayMediaIntent`.
    private func requestSiriAuthorization() {
        guard INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
        INPreferences.requestSiriAuthorization { status in
            CarPlayLog.notice("Siri authorization status=\(status.rawValue)")
        }
    }

    /// iPhone stays portrait-only so layout width never expands into landscape.
    /// iPad keeps all orientations for split view / Stage Manager.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return .portrait
        }
        return .all
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        BackgroundFetchSyncer.performFetch(completion: completionHandler)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        CarPlayLog.notice("configurationForConnecting | role=\(connectingSceneSession.role.rawValue)")
        if connectingSceneSession.role == UISceneSession.Role(
            rawValue: "CPTemplateApplicationSceneSessionRoleApplication"
        ) || connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            config.sceneClass = CPTemplateApplicationScene.self
            CarPlayLog.notice("using CarPlay scene configuration")
            return config
        }
        CarPlayLog.notice("using default scene configuration")
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            CarPlayLog.notice("handlerFor INPlayMediaIntent")
            return PlayMediaIntentHandler()
        }
        return nil
    }

    /// Reached when the intent arrives via a background app launch (a donated
    /// shortcut, or any handler that answered `handleInApp`).
    func application(
        _ application: UIApplication,
        handle intent: INIntent,
        completionHandler: @escaping (INIntentResponse) -> Void
    ) {
        guard let playMedia = intent as? INPlayMediaIntent else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        CarPlayLog.notice("background launch handling INPlayMediaIntent")
        PlayMediaIntentHandler().handle(intent: playMedia) { response in
            completionHandler(response)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Rare on modern iOS, but when it does run we want audio gone immediately.
        MainActor.assumeIsolated {
            VerodromeKit.shared.haltForTermination()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    /// CarPlay treats the Now Playing source as the app to bring forward on connect.
    /// Re-publish that payload when the route becomes the car, and activate the CarPlay
    /// scene if we already have one.
    private func observeCarPlayAudioRoute() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        let onCar = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .carAudio
        }
        guard onCar else { return }
        let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let wasOnCar = previous?.outputs.contains { $0.portType == .carAudio } ?? false
        let pluggedIn = !wasOnCar
        CarPlayLog.notice("audio route is CarPlay | pluggedIn=\(pluggedIn)")
        Task { @MainActor in
            if pluggedIn, VerodromeKit.shared.player?.resumeIfPausedWithQueue() == true {
                CarPlayLog.notice("paused queue on CarPlay route — resuming")
            }
            VerodromeKit.shared.player?.syncPublishedState()
            Self.activateCarPlaySceneIfPlaying(alsoWhenQueued: pluggedIn)
        }
    }

    @MainActor
    private static func activateCarPlaySceneIfPlaying(alsoWhenQueued: Bool = false) {
        let player = VerodromeKit.shared.player
        let hasQueue = player.map { !$0.queue.isEmpty && $0.currentItem != nil } ?? false
        guard player?.isPlaying == true || (alsoWhenQueued && hasQueue) else { return }
        let carRole = UISceneSession.Role.carTemplateApplication
        let session = UIApplication.shared.openSessions.first {
            $0.role == carRole
                || $0.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication"
        }
        guard let session else {
            CarPlayLog.notice("playing on CarPlay route; waiting for the system to create the scene")
            return
        }
        CarPlayLog.notice("requesting CarPlay scene activation")
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil) { error in
            CarPlayLog.error("CarPlay scene activation failed: \(error.localizedDescription)")
        }
    }
}
