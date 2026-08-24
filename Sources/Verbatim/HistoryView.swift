import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = History.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: "%d dictations · %.1f min · ~$%.2f",
                            history.entries.count, history.totalSeconds / 60, history.totalCost))
                    .font(.headline)
                Spacer()
                Button("Clear") { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding()

            Divider()

            if history.entries.isEmpty {
                Spacer()
                Text("Nothing captured yet. Hold the hotkey and talk.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(history.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                            Text(String(format: "%.0f s · ~$%.3f", entry.seconds, entry.cost))
                            Spacer()
                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.declareTypes([.string], owner: nil)
                                pasteboard.setString(entry.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy transcript")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(entry.text.isEmpty ? "(empty)" : entry.text)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}
