import AVFoundation
import CarPlay
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
        CarPlayLog.notice("AppDelegate didFinishLaunching")
        return true
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
        CarPlayLog.notice("audio route is CarPlay")
        Task { @MainActor in
            VerodromeKit.shared.player?.syncPublishedState()
            Self.activateCarPlaySceneIfPlaying()
        }
    }

    @MainActor
    private static func activateCarPlaySceneIfPlaying() {
        guard VerodromeKit.shared.player?.isPlaying == true else { return }
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
