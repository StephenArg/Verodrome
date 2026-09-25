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
        tokenRanges(in: text).map { foldedToken(in: text, range: $0) }
    }

    /// Original-text ranges of tokens that match `words`, for highlighting lyrics.
    public static func matchingRanges(in text: String, words: Set<String>) -> [Range<String.Index>] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        return tokenRanges(in: text).filter { words.contains(foldedToken(in: text, range: $0)) }
    }

    /// Letter / `*` runs in `text`, in original indices so highlights can keep the written casing.
    public static func tokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character == "*" {
                if start == nil { start = index }
            } else if let tokenStart = start {
                ranges.append(tokenStart..<index)
                start = nil
            }
            index = text.index(after: index)
        }
        if let tokenStart = start {
            ranges.append(tokenStart..<text.endIndex)
        }
        return ranges
    }

    private static func foldedToken(in text: String, range: Range<String.Index>) -> String {
        String(text[range]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
