import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let seconds: Double
    let text: String

    var cost: Double { seconds / 60 * History.pricePerMinute }
}

/// Every completed dictation turn, persisted locally so the menu can show
/// running cost and the History window can show what was captured.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    /// gpt-live-transcribe list price. Costs shown are estimates derived
    /// from streamed audio duration.
    static let pricePerMinute = 0.017

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbatim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(text: String, seconds: Double) {
        entries.append(HistoryEntry(id: UUID(), date: Date(), seconds: seconds, text: text))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    var totalSeconds: Double { entries.reduce(0) { $0 + $1.seconds } }
    var totalCost: Double { entries.reduce(0) { $0 + $1.cost } }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }
}
