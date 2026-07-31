import Foundation

/// Parses `verodrome://` and x-callback-url deep links into app actions.
public enum DeepLinkAction: Sendable, Equatable {
    case play(query: String)
    case search(query: String)
    case navigate(destination: String)
    case unknown
}

public enum DeepLinkRouter {
    public static func parse(_ url: URL) -> DeepLinkAction {
        guard let scheme = url.scheme?.lowercased(), scheme == "verodrome" else {
            return .unknown
        }

        let host = (url.host ?? "").lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // verodrome://x-callback-url/play?q=...
        // verodrome://play?q=... / verodrome://search?q=... / verodrome://library
        let action = host == "x-callback-url" ? path : (host.isEmpty ? path : host)

        switch action {
        case "play":
            if let q = query("q") ?? query("query"), !q.isEmpty { return .play(query: q) }
            if let id = query("id"), !id.isEmpty { return .play(query: id) }
            return .unknown
        case "search":
            if let q = query("q") ?? query("query"), !q.isEmpty { return .search(query: q) }
            return .search(query: "")
        case "library", "home", "settings", "downloads", "radios":
            return .navigate(destination: action)
        default:
            if !path.isEmpty { return .navigate(destination: path) }
            return .unknown
        }
    }
}
