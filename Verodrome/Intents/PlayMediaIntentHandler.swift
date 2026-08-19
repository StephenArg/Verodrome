import Foundation
import Intents
import UIKit
import VerodromeKit

/// Carries a spoken query from the Siri intent to the CarPlay scene.
///
/// The live scene installs `receiver` and is called directly. An earlier version
/// posted a `Notification` instead, and the query was lost in that hop: Siri answered
/// successfully while the scene never woke up. A direct call has no delivery to fail.
@MainActor
enum CarPlayVoiceSearch {
    /// Installed by the connected CarPlay scene, cleared when it disconnects.
    static var receiver: ((String) -> Void)?

    private static var pending: String?

    static var isCarPlayConnected: Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.session.configuration.role == .carTemplateApplication
        }
    }

    /// Recording the term here rather than in the scene means it reaches Recently
    /// searched even when the CarPlay UI cannot be updated.
    static func submit(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SearchHistoryStore.record(trimmed)
        guard let receiver else {
            pending = trimmed
            CarPlayLog.notice("voice search \(trimmed) queued; no scene receiver yet")
            return
        }
        pending = nil
        receiver(trimmed)
    }

    static func takePending() -> String? {
        defer { pending = nil }
        return pending
    }

    /// CarPlay times Siri requests aggressively, so wait only long enough for a scene
    /// that is still attaching after a background launch.
    static func waitForReceiver(timeout: Duration) async -> Bool {
        if receiver != nil { return true }
        let step = Duration.milliseconds(200)
        var waited = Duration.zero
        while waited < timeout, receiver == nil {
            try? await Task.sleep(for: step)
            waited += step
        }
        return receiver != nil
    }
}

/// Siri / CarPlay assistant cell delivers `INPlayMediaIntent`. On CarPlay the
/// spoken name is a search query; on the phone it plays the first library match.
///
/// This app handles the intent in-process (iOS 14+ in-app handling) rather than in
/// an Intents extension, so `handle` must finish the work and report `.success`.
/// Returning `.handleInApp` here would ask the system to hand the intent to
/// `application(_:handle:completionHandler:)` and Siri reports a failure if that
/// round trip does not complete.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard let name = Self.query(from: intent) else {
            // Siri speaks its own "can't find that" line for unsupported.
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }
        let item = INMediaItem(
            identifier: "search:\(name)",
            title: name,
            type: .song,
            artwork: nil
        )
        completion([INPlayMediaMediaItemResolutionResult.success(with: item)])
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let query = Self.query(from: intent) else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        Task { @MainActor in
            if CarPlayVoiceSearch.isCarPlayConnected {
                // Only to catch a scene that is still attaching; the query is queued
                // and drained on connect either way, so this stays short.
                _ = await CarPlayVoiceSearch.waitForReceiver(timeout: .milliseconds(1200))
                CarPlayLog.notice("play media intent -> CarPlay search \(query)")
                CarPlayVoiceSearch.submit(query)
                completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                return
            }
            let played = IntentLibraryPlayback.playFirstMatch(named: query)
            CarPlayLog.notice("play media intent -> phone playback \(query) played=\(played)")
            completion(INPlayMediaIntentResponse(code: played ? .success : .failure, userActivity: nil))
        }
    }

    static func query(from intent: INPlayMediaIntent) -> String? {
        let candidates = [
            intent.mediaSearch?.mediaName,
            intent.mediaItems?.first?.title,
            intent.mediaSearch?.artistName,
            intent.mediaItems?.first?.artist
        ]
        for value in candidates {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
