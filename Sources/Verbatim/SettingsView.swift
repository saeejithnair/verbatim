import SwiftUI

struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            SecureField("OpenAI API key", text: $prefs.apiKey)

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
            Text("Lower finalizes text sooner; higher gives the model more context per word.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Keywords (comma-separated)", text: $prefs.keywords)
            Text("Names and jargon the transcriber should recognize.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Transcription prompt") {
                TextEditor(text: $prefs.prompt)
                    .font(.body)
                    .frame(height: 90)
            }

            Toggle("Play sounds", isOn: $prefs.playSounds)
        }
        .padding(20)
        .frame(width: 460)
    }
}
