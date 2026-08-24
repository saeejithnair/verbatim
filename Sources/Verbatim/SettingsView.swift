import SwiftUI

struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("General") {
                SecureField("OpenAI API key", text: $prefs.apiKey)
                caption("Stored only on this Mac. Leave empty to use OPENAI_API_KEY from your environment.")
                Toggle("Play sounds", isOn: $prefs.playSounds)
            }

            Section("Dictation") {
                Picker("Hold to dictate", selection: $prefs.hotkey) {
                    ForEach(ModifierKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: prefs.hotkey) { _, newKey in
                    HotkeyMonitor.shared.start(modifierKey: newKey)
                }

                Picker("Latency", selection: $prefs.delay) {
                    ForEach(TranscriptionDelay.allCases) { delay in
                        Text(delay.rawValue).tag(delay)
                    }
                }
                caption("Lower finalizes text sooner; higher gives the model more context per word.")
            }

            Section("Keywords") {
                KeywordsEditor()
            }

            Section("Transcription prompt") {
                TextEditor(text: $prefs.prompt)
                    .font(.body)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                caption("Sent with every dictation. The default demands strict verbatim output.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Keyword chips: type a word, press Return, it becomes a capsule; click the
/// ✕ (or the chip's hover state) to remove it. Backed by the same
/// comma-separated preference as before.
struct KeywordsEditor: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var words: [String] { prefs.keywordList }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if words.isEmpty {
                Text("Add the names and jargon you actually say — they stop getting mangled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // The text field lives inside the flow, where the next chip will
            // appear — type, Return, chip. Backspace on an empty field
            // removes the last chip.
            FlowLayout(spacing: 8) {
                ForEach(words, id: \.self) { word in
                    KeywordChip(word: word) { remove(word) }
                }

                TextField("", text: $draft,
                          prompt: Text(words.isEmpty ? "Type a keyword, press Return" : "Add…"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($fieldFocused)
                    .onSubmit(addDraft)
                    .onKeyPress(.delete) {
                        guard draft.isEmpty, let last = words.last else { return .ignored }
                        remove(last)
                        return .handled
                    }
                    .frame(minWidth: 140, maxWidth: 180)
                    .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
    }

    private func addDraft() {
        let word = draft.trimmingCharacters(in: .whitespaces)
        draft = ""
        fieldFocused = true
        guard !word.isEmpty,
              !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
        else { return }
        withAnimation(.spring(duration: 0.3)) {
            prefs.keywords = (words + [word]).joined(separator: ", ")
        }
    }

    private func remove(_ word: String) {
        withAnimation(.spring(duration: 0.25)) {
            prefs.keywords = words.filter { $0 != word }.joined(separator: ", ")
        }
    }
}

struct KeywordChip: View {
    let word: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.callout)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help("Remove \(word)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.22 : 0.14)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3)))
        .onHover { hovering = $0 }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Minimal left-aligned wrapping layout for the chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
