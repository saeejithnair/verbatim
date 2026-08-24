import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let seconds: Double
    let text: String
    /// Key release → transcript ready. The felt latency.
    let finalizeSeconds: Double?

    var cost: Double { seconds / 60 * History.pricePerMinute }
}

/// One day's dictation activity. Lifetime stats live separately from the
/// history list so clearing history never erases the record of having spoken.
struct DayStat: Codable {
    var words = 0
    var seconds: Double = 0
    var count = 0
}

/// Every completed dictation turn, persisted locally so the menu can show
/// running cost and the History window can show what was captured.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    /// gpt-live-transcribe list price. Costs shown are estimates derived
    /// from streamed audio duration.
    nonisolated static let pricePerMinute = 0.017

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var days: [String: DayStat] = [:]

    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbatim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let fileURL = supportDir.appendingPathComponent("history.json")
    private let statsURL = supportDir.appendingPathComponent("stats.json")

    nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
        if let data = try? Data(contentsOf: statsURL),
           let saved = try? JSONDecoder().decode([String: DayStat].self, from: data) {
            days = saved
        } else if !entries.isEmpty {
            // First run after the stats feature shipped: backfill from history.
            for entry in entries {
                bump(day: Self.dayKey(entry.date), words: Self.wordCount(entry.text),
                     seconds: entry.seconds)
            }
            saveStats()
        }
    }

    func add(text: String, seconds: Double, finalizeSeconds: Double? = nil) {
        let now = Date()
        entries.append(HistoryEntry(id: UUID(), date: now, seconds: seconds,
                                    text: text, finalizeSeconds: finalizeSeconds))
        bump(day: Self.dayKey(now), words: Self.wordCount(text), seconds: seconds)
        save()
        saveStats()
    }

    /// Clears the transcript list. Lifetime day stats survive.
    func clear() {
        entries = []
        save()
    }

    var totalSeconds: Double { entries.reduce(0) { $0 + $1.seconds } }
    var totalCost: Double { entries.reduce(0) { $0 + $1.cost } }
    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }

    private func bump(day: String, words: Int, seconds: Double) {
        var stat = days[day] ?? DayStat()
        stat.words += words
        stat.seconds += seconds
        stat.count += 1
        days[day] = stat
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: statsURL)
        }
    }
}
