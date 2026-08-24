import Foundation

enum TranscriptionDelay: String, CaseIterable, Identifiable {
    case minimal, low, medium, high, xhigh

    var id: String { rawValue }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()

    static let defaultPrompt = """
    Transcribe exactly what is spoken, verbatim. Keep every filler word \
    (um, uh, like, you know), false start, repetition, and self-correction. \
    Do not clean up, rephrase, or omit anything.
    """

    /// Starter keyword set for the app's core audience: people dictating to
    /// AI coding agents.
    static let defaultKeywords = "Claude Code, Codex, PR, Supabase"

    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "apiKey") } }
    @Published var hotkey: ModifierKey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var delay: TranscriptionDelay { didSet { defaults.set(delay.rawValue, forKey: "delay") } }
    @Published var prompt: String { didSet { defaults.set(prompt, forKey: "prompt") } }
    @Published var keywords: String { didSet { defaults.set(keywords, forKey: "keywords") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var endSound: Bool { didSet { defaults.set(endSound, forKey: "endSound") } }
    @Published var trailingSpace: Bool { didSet { defaults.set(trailingSpace, forKey: "trailingSpace") } }
    @Published var languages: String { didSet { defaults.set(languages, forKey: "languages") } }

    private init() {
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        hotkey = ModifierKey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        delay = TranscriptionDelay(rawValue: defaults.string(forKey: "delay") ?? "") ?? .medium
        prompt = defaults.string(forKey: "prompt") ?? Self.defaultPrompt
        keywords = defaults.string(forKey: "keywords") ?? Self.defaultKeywords
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        endSound = defaults.object(forKey: "endSound") as? Bool ?? true
        trailingSpace = defaults.object(forKey: "trailingSpace") as? Bool ?? true
        languages = defaults.string(forKey: "languages") ?? ""
    }

    /// The Settings field wins; falls back to the process environment, then to
    /// ~/.config/verbatim/.env (a line of the form OPENAI_API_KEY=sk-...).
    /// The fallback is resolved once per launch — it otherwise puts a
    /// synchronous file read on every keyDown.
    func resolvedAPIKey() -> String? {
        if !apiKey.isEmpty { return apiKey }
        return fallbackKey
    }

    private lazy var fallbackKey: String? = {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/verbatim/.env")
        if let text = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("OPENAI_API_KEY=") {
                let value = String(line.dropFirst("OPENAI_API_KEY=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }()

    var keywordList: [String] {
        keywords.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // The API rejects keywords containing angle brackets or newlines;
            // one bad entry would poison every session.
            .map { $0.replacingOccurrences(of: "[<>\r\n]", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    /// ISO 639-1 codes; empty = auto-detect. Locking languages stops the
    /// model drifting into another script mid-sentence.
    var languageList: [String] {
        languages.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Prompt sentence generated from the language setting — belt to the
    /// `languages` parameter's suspenders. Nil when auto-detecting.
    var languageClause: String? {
        let names = languageList.compactMap {
            Locale(identifier: "en").localizedString(forLanguageCode: $0) ?? $0
        }
        guard !names.isEmpty else { return nil }
        return "The speaker speaks only \(names.joined(separator: " or ")). Transcribe in that language."
    }
}

enum VerbatimError: LocalizedError {
    case missingAPIKey
    case audioSetup(String)
    case transcription(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No OpenAI API key — set one in Settings"
        case .audioSetup(let detail): "Audio setup failed: \(detail)"
        case .transcription(let detail): detail
        case .timeout: "Transcription timed out"
        }
    }
}
