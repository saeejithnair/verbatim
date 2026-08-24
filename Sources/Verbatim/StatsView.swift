import SwiftUI

/// Lifetime words + a contribution heatmap of the last twelve weeks.
/// A record, not a scoreboard: it celebrates what was said and never nags
/// about quiet days.
struct StatsView: View {
    @ObservedObject private var history = History.shared

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(history.totalWords)")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.5), value: history.totalWords)
                Text("words dictated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ContributionGraph(days: history.days)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct ContributionGraph: View {
    let days: [String: DayStat]

    private let weeks = 12
    private let cell: CGFloat = 9
    private let gap: CGFloat = 2.5

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekdayIndex = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -(7 * (weeks - 1) + weekdayIndex), to: today)!

        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                        if date > today {
                            Color.clear.frame(width: cell, height: cell)
                        } else {
                            let words = days[History.dayKey(date)]?.words ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: words))
                                .frame(width: cell, height: cell)
                                .overlay {
                                    if date == today {
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
                                    }
                                }
                                .help("\(date.formatted(.dateTime.month().day())) — \(words) words")
                        }
                    }
                }
            }
        }
    }

    private func color(for words: Int) -> Color {
        switch words {
        case 0: .secondary.opacity(0.12)
        case ..<100: .accentColor.opacity(0.3)
        case ..<400: .accentColor.opacity(0.55)
        case ..<1000: .accentColor.opacity(0.8)
        default: .accentColor
        }
    }
}
