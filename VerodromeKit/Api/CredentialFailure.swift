import Foundation

/// The stored username/password is no longer accepted.
///
/// Subsonic and Navidrome send the password (or a hash of it) on every REST call, so
/// code `40` / HTTP `401` means the account itself is wrong — not a missing permission.
/// Ampache's equivalent is handshake code `4703`. Codes that look similar but are not
/// this, and must not sign the user out:
///
/// - Subsonic `41` / `42`: this client or server does not speak that auth scheme.
///   `BackendProxy` tries token, then Ampache, then legacy; `41` is the expected
///   miss while probing.
/// - Subsonic `50` / Ampache XML `401`: the user is signed in but cannot do *this*
///   operation (sharing off, admin-only method, someone else's playlist).
/// - Ampache `4701`: the *session* expired. The password may still be fine.
enum CredentialFailure {
    private static let suppress = Counter()

    /// Subsonic `40`, Ampache invalid handshake `4703`, or HTTP 401 on a call that
    /// authenticates with the password itself (Subsonic REST, Navidrome `/auth/login`).
    static func matches(_ error: Error) -> Bool {
        if let xml = error as? XmlParseError, case .serverError(let code, _) = xml {
            return code == 40 || code == 4703
        }
        if let api = error as? BackendApiError, case .http(let status, _) = api {
            return status == 401
        }
        return false
    }

    /// Login detection walks several API dialects with the same password. A `40` from
    /// the first candidate is "not this dialect", not "wipe the current session" —
    /// especially while adding a second account, when the active session is still valid.
    static func ignoring<T>(_ body: () async throws -> T) async throws -> T {
        suppress.increment()
        defer { suppress.decrement() }
        return try await body()
    }

    /// Posts `.credentialsRejected` unless a login probe is in flight. The session flag
    /// on the transport should already have been cleared by the caller.
    static func reportIfNeeded(_ error: Error) {
        guard matches(error), !suppress.isSuppressed else { return }
        NotificationCenter.default.post(name: .credentialsRejected, object: nil)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var depth = 0

        func increment() {
            lock.lock()
            depth += 1
            lock.unlock()
        }

        func decrement() {
            lock.lock()
            depth -= 1
            lock.unlock()
        }

        var isSuppressed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return depth > 0
        }
    }
}
