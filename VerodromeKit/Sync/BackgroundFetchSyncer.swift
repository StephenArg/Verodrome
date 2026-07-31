import Foundation

@MainActor
public final class BackgroundFetchSyncer {
    public static let taskIdentifier = "com.verodrome.app.RefreshTask"
    @MainActor public static var shared: BackgroundFetchSyncer?

    private let librarySyncer: BackgroundLibrarySyncer
    private let policyPrune: (() -> Void)?

    public init(librarySyncer: BackgroundLibrarySyncer, policyPrune: (() -> Void)? = nil) {
        self.librarySyncer = librarySyncer
        self.policyPrune = policyPrune
    }

    public func run() async {
        _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()
        await librarySyncer.syncNewest()
        policyPrune?()
    }

    public static func performFetch(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await shared?.run()
            completion(.noData)
        }
    }
}

import UIKit
