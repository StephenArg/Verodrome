import Foundation

/// Whole-token matching of lyrics against an explicit-language word set.
public enum LyricsExplicitMatcher {
    public static func activeWords(
        sensitivity: LyricsExplicitSensitivity,
        blacklist: [String],
        whitelist: [String]
    ) -> Set<String> {
        let extra = Set(UserSettings.normalizedWords(blacklist))
        let allowed = Set(UserSettings.normalizedWords(whitelist))
        return LyricsExplicitWordLists.words(for: sensitivity).union(extra).subtracting(allowed)
    }

    public static func activeWords(in settings: UserSettings) -> Set<String> {
        activeWords(
            sensitivity: settings.explicitSensitivity,
            blacklist: settings.explicitBlacklistWords,
            whitelist: settings.explicitWhitelistWords
        )
    }

    /// Strips LRC timestamps and metadata, then checks for a whole-token hit.
    public static func isExplicit(_ lyrics: String, words: Set<String>) -> Bool {
        guard !words.isEmpty else { return false }
        let text = plainText(from: lyrics)
        guard !text.isEmpty else { return false }
        for token in tokens(in: text) where words.contains(token) {
            return true
        }
        return false
    }

    public static func isExplicit(_ lyrics: String, settings: UserSettings) -> Bool {
        isExplicit(lyrics, words: activeWords(in: settings))
    }

    public static func plainText(from lyrics: String) -> String {
        LyricsParser.parse(lyrics)
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Letter runs, keeping `*` so starred spellings on the lists can match.
    public static func tokens(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var tokens: [String] = []
        var current = ""
        for character in folded {
            if character.isLetter || character == "*" {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
