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

    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "apiKey") } }
    @Published var hotkey: ModifierKey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var delay: TranscriptionDelay { didSet { defaults.set(delay.rawValue, forKey: "delay") } }
    @Published var prompt: String { didSet { defaults.set(prompt, forKey: "prompt") } }
    @Published var keywords: String { didSet { defaults.set(keywords, forKey: "keywords") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var trailingSpace: Bool { didSet { defaults.set(trailingSpace, forKey: "trailingSpace") } }

    private init() {
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        hotkey = ModifierKey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        delay = TranscriptionDelay(rawValue: defaults.string(forKey: "delay") ?? "") ?? .medium
        prompt = defaults.string(forKey: "prompt") ?? Self.defaultPrompt
        keywords = defaults.string(forKey: "keywords") ?? ""
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        trailingSpace = defaults.object(forKey: "trailingSpace") as? Bool ?? true
    }

    /// The Settings field wins; falls back to the process environment, then to
    /// the development .env one directory above the package.
    func resolvedAPIKey() -> String? {
        if !apiKey.isEmpty { return apiKey }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("personal/dictation/.env")
        if let text = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("OPENAI_API_KEY=") {
                let value = String(line.dropFirst("OPENAI_API_KEY=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    var keywordList: [String] {
        keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
