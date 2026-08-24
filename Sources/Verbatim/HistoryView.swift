import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = History.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("^[\(history.entries.count) dictation](inflect: true) · \(String(format: "%.1f", history.totalSeconds / 60)) min · ~\(String(format: "$%.2f", history.totalCost))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if history.entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Nothing captured yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Hold \(Prefs.shared.hotkey.displayName) and talk.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history.entries.reversed()) { entry in
                            HistoryCard(entry: entry)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

struct HistoryCard: View {
    let entry: HistoryEntry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Group {
                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                    Text("·")
                    Text(String(format: "%.0f s", entry.seconds))
                    if let finalize = entry.finalizeSeconds {
                        Text("·")
                        Label(String(format: "%.1f s", finalize), systemImage: "bolt.fill")
                            .labelStyle(.titleAndIcon)
                            .help("Key release → text pasted")
                    }
                    Text("·")
                    Text(String(format: "~$%.3f", entry.cost))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

                Spacer()

                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .opacity(hovering || copied ? 1 : 0)
                .help("Copy transcript")
            }

            Text(entry.text.isEmpty ? "(empty)" : entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(hovering ? 0.7 : 0.45))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(entry.text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copied = false }
        }
    }
}
