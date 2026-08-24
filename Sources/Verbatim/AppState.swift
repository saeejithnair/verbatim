import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case idle, recording, finalizing
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var lastTranscript = ""

    private var streamer: AudioStreamer?
    private var transcriber: RealtimeTranscriber?
    private var holdStart: Date?

    /// Releases shorter than this are accidental taps; nothing is pasted.
    static let minimumHold: TimeInterval = 0.3

    func keyDown() {
        switch phase {
        case .idle, .error: break
        case .recording, .finalizing: return
        }

        guard let apiKey = Prefs.shared.resolvedAPIKey() else {
            fail(VerbatimError.missingAPIKey.localizedDescription)
            return
        }

        holdStart = Date()
        // Connect while the first words are being spoken; audio is buffered
        // until the socket opens.
        let transcriber = RealtimeTranscriber(apiKey: apiKey)
        self.transcriber = transcriber
        transcriber.connect()

        let streamer = AudioStreamer()
        streamer.onChunk = { [weak transcriber] data in transcriber?.append(data) }
        do {
            try streamer.start()
        } catch {
            transcriber.cancel()
            self.transcriber = nil
            fail(error.localizedDescription)
            return
        }
        self.streamer = streamer
        phase = .recording
        if Prefs.shared.playSounds { NSSound(named: "Tink")?.play() }
    }

    func keyUp() {
        guard case .recording = phase, let transcriber else { return }
        streamer?.stop()
        streamer = nil

        let held = Date().timeIntervalSince(holdStart ?? Date())
        guard held >= Self.minimumHold else {
            transcriber.cancel()
            self.transcriber = nil
            phase = .idle
            return
        }

        phase = .finalizing
        Task {
            do {
                let text = try await transcriber.finish()
                self.lastTranscript = text
                History.shared.add(text: text, seconds: transcriber.streamedSeconds)
                if !text.isEmpty {
                    Paster.insertText(text)
                    if Prefs.shared.playSounds { NSSound(named: "Pop")?.play() }
                }
                self.phase = .idle
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.fail(error.localizedDescription)
            }
            self.transcriber = nil
        }
    }

    private func fail(_ message: String) {
        phase = .error(message)
        if Prefs.shared.playSounds { NSSound(named: "Basso")?.play() }
    }

    var menuIcon: String {
        switch phase {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .finalizing: "ellipsis.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var statusLine: String {
        switch phase {
        case .idle: "Hold \(Prefs.shared.hotkey.displayName) to dictate"
        case .recording: "Listening…"
        case .finalizing: "Transcribing…"
        case .error(let message): "Error: \(message)"
        }
    }
}
