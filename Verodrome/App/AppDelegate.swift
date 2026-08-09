import AVFoundation
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
}
