import AppKit
import SwiftUI

/// One dictation: its mic stream, its realtime socket, and — crucially — a
/// local copy of every audio chunk, so no failure can lose the words.
@MainActor
final class DictationTurn {
    let transcriber: RealtimeTranscriber
    let streamer = AudioStreamer()
    var captured: [Data] = []
    var peak: Int16 = 0
    /// Socket died while recording; skip realtime finish, go straight to batch.
    var degraded = false
    let startedAt = Date()

    init(apiKey: String) {
        transcriber = RealtimeTranscriber(apiKey: apiKey)
    }

    var capturedSeconds: Double {
        Double(captured.reduce(0) { $0 + $1.count }) / 48_000.0
    }

    var capturedPCM: Data {
        captured.reduce(into: Data()) { $0.append($1) }
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case idle, recording, finalizing
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var lastTranscript = ""
    @Published var accessibilityGranted = true
    @Published var hotkeyActive = true
    @Published var latched = false

    private var currentTurn: DictationTurn?
    private var provisionalCancel: Task<Void, Never>?
    private var swallowNextKeyUp = false
    private var pressStartedAt: Date?
    private var secondPress = false
    private var finalizingCount = 0
    /// Screen lock or a tap timeout can eat the key-up event, wedging the app
    /// in .recording with the mic hot. While a non-latched hold is active,
    /// poll the real hardware modifier state and synthesize the release.
    private var holdWatchdog: Timer?
    /// Pastes held back while a hotkey is physically down, so a synthesized
    /// Cmd+V never fires with a modifier held. Flushed when the mic is free.
    private var pendingPastes: [String] = []

    /// Releases shorter than this are taps, not dictations.
    static let minimumHold: TimeInterval = 0.3
    /// Two taps within this window latch hands-free recording.
    static let doubleTapWindow: TimeInterval = 0.35
    /// Peak sample amplitude below this means the mic delivered silence.
    static let silenceFloor: Int16 = 500

    // MARK: - Key handling

    func keyDown() {
        if latched {
            // Tap while latched: end the take.
            swallowNextKeyUp = true
            latched = false
            commitCurrentTurn()
            return
        }
        pressStartedAt = Date()
        if provisionalCancel != nil {
            // Second press inside the double-tap window. The turn from the
            // first tap is still recording; whether this press latches or is
            // a normal hold is decided at its release.
            provisionalCancel?.cancel()
            provisionalCancel = nil
            secondPress = true
            return
        }
        guard currentTurn == nil else { return }
        startTurn()
    }

    func keyUp() {
        if swallowNextKeyUp {
            swallowNextKeyUp = false
            return
        }
        guard let turn = currentTurn, !latched else { return }
        let pressHeld = Date().timeIntervalSince(pressStartedAt ?? turn.startedAt)

        if secondPress {
            secondPress = false
            if pressHeld < Self.minimumHold {
                // Double-tap: latch hands-free.
                latched = true
            } else {
                // Tap-then-hold: an ordinary dictation that happened to start
                // with a stray tap. Commit like any release.
                commitCurrentTurn()
            }
            return
        }

        if pressHeld < Self.minimumHold {
            // Maybe the first tap of a double-tap latch: keep recording until
            // the window closes, then treat it as a nevermind.
            provisionalCancel = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
                guard !Task.isCancelled else { return }
                self?.provisionalCancel = nil
                self?.cancelCurrentTurn()
            }
            return
        }
        commitCurrentTurn()
    }

    func repasteLast() {
        guard !lastTranscript.isEmpty else {
            if Prefs.shared.playSounds { NSSound(named: "Bottle")?.play() }
            return
        }
        if Paster.insertText(Prefs.shared.trailingSpace ? lastTranscript + " " : lastTranscript) {
            if Prefs.shared.playSounds && Prefs.shared.endSound { NSSound(named: "Pop")?.play() }
        } else {
            fail("Secure input is active — the transcript is on your clipboard, press ⌘V")
        }
    }

    // MARK: - Turn lifecycle

    private func startTurn() {
        guard let apiKey = Prefs.shared.resolvedAPIKey() else {
            fail(VerbatimError.missingAPIKey.localizedDescription)
            return
        }

        let turn = DictationTurn(apiKey: apiKey)
        turn.transcriber.onConnectionLost = { [weak self, weak turn] in
            Task { @MainActor in
                guard let turn, turn === self?.currentTurn, !turn.degraded else { return }
                turn.degraded = true
                if Prefs.shared.playSounds { NSSound(named: "Basso")?.play() }
            }
        }
        turn.streamer.onChunk = { [weak turn] data, peak in
            DispatchQueue.main.async {
                guard let turn else { return }
                turn.captured.append(data)
                turn.peak = max(turn.peak, peak)
                turn.transcriber.append(data)
            }
        }

        do {
            try turn.streamer.start()
        } catch {
            turn.transcriber.cancel()
            fail(error.localizedDescription)
            return
        }
        turn.transcriber.connect()
        currentTurn = turn
        phase = .recording
        if Prefs.shared.playSounds { NSSound(named: "Tink")?.play() }

        holdWatchdog?.invalidate()
        holdWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard currentTurn != nil, !latched, provisionalCancel == nil, !secondPress else { return }
        let flag = Prefs.shared.hotkey.cgEventFlag
        guard flag != [] else { return }
        if !CGEventSource.flagsState(.combinedSessionState).contains(flag) {
            keyUp()
        }
    }

    private func cancelCurrentTurn() {
        guard let turn = currentTurn else { return }
        currentTurn = nil
        holdWatchdog?.invalidate()
        holdWatchdog = nil
        turn.streamer.stop()
        turn.transcriber.cancel()
        if Prefs.shared.playSounds { NSSound(named: "Bottle")?.play() }
        settlePhase()
    }

    private func commitCurrentTurn() {
        guard let turn = currentTurn else { return }
        currentTurn = nil
        holdWatchdog?.invalidate()
        holdWatchdog = nil
        finalizingCount += 1
        settlePhase()
        let releasedAt = Date()
        Task {
            // Capture the human tail — the syllable still leaving the mouth
            // as the finger lifts — before closing the stream.
            try? await Task.sleep(for: .milliseconds(120))
            turn.streamer.stop()
            await finalize(turn, releasedAt: releasedAt)
        }
    }

    private func finalize(_ turn: DictationTurn, releasedAt: Date) async {
        var text: String?
        var failureMessage: String?

        if turn.degraded {
            turn.transcriber.cancel()
        } else {
            do {
                // Long rambles need proportionally longer to flush.
                let timeout = max(12, turn.capturedSeconds * 0.4)
                text = try await turn.transcriber.finish(timeout: timeout)
            } catch is CancellationError {
                // fall through to batch
            } catch {
                failureMessage = error.localizedDescription
            }
        }

        if text == nil {
            // Realtime failed: the local buffer is the source of truth.
            let pcm = turn.capturedPCM
            if pcm.isEmpty {
                failureMessage = failureMessage ?? "no audio captured"
            } else if let apiKey = Prefs.shared.resolvedAPIKey() {
                let saved = try? BatchTranscriber.savePending(pcm: pcm)
                do {
                    text = try await BatchTranscriber.transcribe(
                        pcm: pcm, apiKey: apiKey, prompt: Self.batchPrompt())
                    if let saved { try? FileManager.default.removeItem(at: saved) }
                    failureMessage = nil
                } catch {
                    failureMessage = "\(error.localizedDescription) — audio saved, recovered to history on next launch"
                }
            }
        }

        finalizingCount -= 1

        if let text {
            lastTranscript = text
            History.shared.add(text: text, seconds: turn.capturedSeconds,
                               finalizeSeconds: Date().timeIntervalSince(releasedAt),
                               truncated: turn.transcriber.timedOutWithPartial)
            if text.isEmpty {
                if turn.peak < Self.silenceFloor {
                    fail("No audio reached the app — check your input device")
                } else {
                    if Prefs.shared.playSounds { NSSound(named: "Bottle")?.play() }
                    settlePhase()
                }
            } else {
                deliver(text)
                settlePhase()
            }
        } else if let failureMessage {
            fail(failureMessage)
        } else {
            settlePhase()
        }
    }

    /// Recover WAVs parked by failed turns from previous runs: transcribe
    /// them into history (never paste — focus is unpredictable at launch).
    func recoverPendingAudio() async {
        guard let apiKey = Prefs.shared.resolvedAPIKey() else { return }
        for url in BatchTranscriber.pendingFiles() {
            guard let text = try? await BatchTranscriber.transcribe(
                fileURL: url, apiKey: apiKey, prompt: Self.batchPrompt()) else { continue }
            History.shared.add(text: text, seconds: BatchTranscriber.duration(of: url))
            try? FileManager.default.removeItem(at: url)
            lastTranscript = text
        }
    }

    private static func batchPrompt() -> String {
        var prompt = Prefs.shared.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = Prefs.shared.keywordList
        if !keywords.isEmpty {
            prompt += "\nExpect these terms: \(keywords.joined(separator: ", "))."
        }
        if let clause = Prefs.shared.languageClause {
            prompt += "\n" + clause
        }
        return prompt
    }

    // MARK: - Delivery & phase

    private func deliver(_ text: String) {
        let payload = Prefs.shared.trailingSpace ? text + " " : text
        if currentTurn != nil {
            pendingPastes.append(payload)
        } else {
            flushPendingPastes()
            if Paster.insertText(payload) {
                if Prefs.shared.playSounds && Prefs.shared.endSound {
                    NSSound(named: "Pop")?.play()
                }
            } else {
                fail("Secure input is active — the transcript is on your clipboard, press ⌘V")
            }
        }
    }

    private func flushPendingPastes() {
        var blocked = false
        for payload in pendingPastes where !Paster.insertText(payload) {
            blocked = true
        }
        pendingPastes.removeAll()
        if blocked {
            fail("Secure input is active — a transcript is on your clipboard, press ⌘V")
        }
    }

    private func settlePhase() {
        if currentTurn != nil {
            phase = .recording
            return
        }
        flushPendingPastes()
        if case .error = phase { return }
        phase = finalizingCount > 0 ? .finalizing : .idle
    }

    private func fail(_ message: String) {
        if currentTurn != nil {
            // Mid-recording: don't hijack the icon; the sound is the signal.
            if Prefs.shared.playSounds { NSSound(named: "Basso")?.play() }
            return
        }
        phase = .error(message)
        if Prefs.shared.playSounds { NSSound(named: "Basso")?.play() }
    }

    // MARK: - Presentation

    var iconColor: Color {
        switch phase {
        case .idle: .secondary
        case .recording: .red
        case .finalizing: .blue
        case .error: .yellow
        }
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
        case .recording: latched ? "Listening (latched — tap to finish)…" : "Listening…"
        case .finalizing: "Transcribing…"
        case .error(let message): "Error: \(message)"
        }
    }
}
