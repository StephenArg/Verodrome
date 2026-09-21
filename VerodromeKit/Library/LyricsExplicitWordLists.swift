import Foundation

/// Built-in word sets for lyrics explicit detection. Custom additions live in settings.
public enum LyricsExplicitWordLists {
    public static func words(for sensitivity: LyricsExplicitSensitivity) -> Set<String> {
        let raw: Set<String>
        switch sensitivity {
        case .loose: raw = loose
        case .average: raw = average
        case .conservative: raw = conservative
        }
        // Lyrics tokens are case- and accent-folded; fold the lists the same way so
        // `cabrón` / `scheiße` still match.
        return Set(raw.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
    }

    /// Strongest terms only.
    public static let loose: Set<String> = [
        "fuck", "fucker", "fuckers", "fucking", "fucks", "motherfucker", "motherfuckers",
        "motherfucking", "cunt", "cunts", "faggot", "faggots", "nigger", "niggers",
        "nigga", "niggas",
        // Spanish
        "joder", "jodido", "jodida", "chingar", "chinga", "chingada", "chingado",
        "verga", "maricón", "maricon",
        // French
        "enculé", "encule", "enculée", "enculee", "nique", "niquer",
        // German
        "fick", "ficken", "gefickt", "fotze", "hurensohn",
        // Italian
        "vaffanculo", "fanculo",
        "porcodio", "porcoddio", "diocane", "porcamadonna", "diobestia",
        "diomerda", "dioporco", "madonnaputtana",
        // Portuguese
        "foder", "foda",
        // Polish
        "kurwa", "chuj", "jebać", "jebac",
        // Russian
        "хуй", "пизда", "ебать", "блядь",
        // Korean
        "시발", "씨발",
    ]

    /// Common strong profanity, including the loose set.
    public static let average: Set<String> = loose.union([
        "pussy", "pussies",
        "cock", "cocks",
        "f*ck", "f*cker", "f*cking",
        "rape", "raped", "raping", "rapist",
        // Spanish
        "carajo", "gilipollas", "cojones", "hijueputa",
        // French
        "connard", "connasse", "salope", "bordel", "foutre",
        // German
        "scheiße", "scheisse", "schlampe", "wichser", "arschloch",
        // Italian
        "cazzo", "puttana", "stronzo", "coglione",
        // Portuguese
        "caralho", "porra", "buceta",
        // Dutch
        "kut", "klootzak", "lul",
        // Russian
        "сука",
    ])

    /// Milder swear words on top of the average set.
    public static let conservative: Set<String> = average.union([
        "ass", "asses", "arse", "arses", "arsehole", "arseholes",
        "damn", "damned", "dammit", "goddamn", "goddamned",
        "hell", "hells",
        "crap", "crappy", "cockhead",
        "piss", "pissed", "pissing",
        "whore", "whores",
        "slut", "sluts",
        "shit", "shits", "shitty", "bullshit", "horseshit", "sh*t",
        "bitch", "bitches", "bitchy", "b*tch",
        "asshole", "assholes", "a**hole", "a**holes",
        "dick", "dicks", "dickhead", "dickheads",
        "bastard", "bastards",
        "twat", "twats",
        "wank", "wanker", "wankers",
        "shite",
        "bloody",
        "bollocks",
        "bugger",
        "tit", "tits", "titties",
        "boob", "boobs",
        "prick", "pricks",
        "douche", "douchebag",
        // Spanish
        "pinche", "culo", "mierda", "puta", "puto", "putas", "putos", "cabrón", "cabron",
        "pendejo", "pendeja", 
        // French
        "chier", "chiant", "putain", "merde", 
        // German
        "arsch", "verdammt",
        // Italian
        "minchia", "merda",
        // Dutch
        "godverdomme",
    ])
}
