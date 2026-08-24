import AppKit
import SwiftUI

/// One dictation: its mic stream, its realtime socket, and — crucially — a
/// local copy of every audio chunk, so no failure can lose the words.
@MainActor
final class DictationTurn {
    let transcriber: RealtimeTranscriber
    let streamer = AudioStreamer()
    var captured = Data()
    var peak: Int16 = 0
    /// Socket died while recording; skip realtime finish, go straight to batch.
    var degraded = false
    /// First audible chunk arrived — the mic is genuinely live (Bluetooth
    /// mics take a second or two to wake).
    var heardAudio = false
    let startedAt = Date()

    init(apiKey: String) {
        transcriber = RealtimeTranscriber(apiKey: apiKey)
        captured.reserveCapacity(48_000 * 60)
    }

    var capturedSeconds: Double {
        Double(captured.count) / 48_000.0
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
    /// Hardware event time (uptime seconds) — Date() at handler time lies
    /// when startTurn's blocking work delays the run loop.
    private var pressStartedUptime: TimeInterval?
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
    /// A forgotten latched take (or a truly lost release) auto-commits here.
    static let maxTurnSeconds: TimeInterval = 900

    nonisolated private static func uptimeNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Key handling

    func keyDown(at eventTime: TimeInterval = AppState.uptimeNow()) {
        if latched {
            // Tap while latched: end the take.
            swallowNextKeyUp = true
            latched = false
            commitCurrentTurn()
            return
        }
        pressStartedUptime = eventTime
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

    func keyUp(at eventTime: TimeInterval = AppState.uptimeNow()) {
        if swallowNextKeyUp {
            swallowNextKeyUp = false
            settlePhase()
            return
        }
        guard currentTurn != nil, !latched else { return }
        let pressHeld = eventTime - (pressStartedUptime ?? eventTime)

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
            provisionalCancel?.cancel()
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
            if Prefs.shared.playSounds { Sfx.nevermind?.play() }
            return
        }
        if Paster.insertText(Prefs.shared.trailingSpace ? lastTranscript + " " : lastTranscript) {
            if Prefs.shared.playSounds && Prefs.shared.endSound { Sfx.landed?.play() }
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
                if Prefs.shared.playSounds { Sfx.trouble?.play() }
            }
        }
        turn.streamer.onChunk = { [weak turn] data, peak in
            DispatchQueue.main.async {
                guard let turn else { return }
                turn.captured.append(data)
                turn.peak = max(turn.peak, peak)
                turn.transcriber.append(data)
                // The start cue fires when sound is actually arriving, not at
                // keypress — on Bluetooth mics those moments are seconds
                // apart, and speech before the wake-up never reaches the Mac.
                if !turn.heardAudio && peak > 300 {
                    turn.heardAudio = true
                    if Prefs.shared.playSounds { Sfx.begin?.play() }
                }
            }
        }

        // The connect is ~300 ms of network; the engine start blocks the main
        // thread. Kick the network off first so they overlap.
        turn.transcriber.connect()
        do {
            try turn.streamer.start()
        } catch {
            turn.transcriber.cancel()
            fail(error.localizedDescription)
            return
        }
        currentTurn = turn
        phase = .recording

        holdWatchdog?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        // .common so the watchdog survives menu tracking and window resize —
        // exactly when the main thread is busiest.
        RunLoop.main.add(timer, forMode: .common)
        holdWatchdog = timer
    }

    private func watchdogTick() {
        guard let turn = currentTurn else { return }

        // A forgotten latched take (or a wedge this watchdog can't see)
        // commits rather than recording forever.
        if Date().timeIntervalSince(turn.startedAt) > Self.maxTurnSeconds {
            if Prefs.shared.playSounds { Sfx.trouble?.play() }
            latched = false
            commitCurrentTurn()
            return
        }

        guard !latched, provisionalCancel == nil, !secondPress else { return }
        let flag = Prefs.shared.hotkey.cgEventFlag
        guard flag != [] else { return }
        if !CGEventSource.flagsState(.combinedSessionState).contains(flag) {
            keyUp()
            // Keep the monitor's press state in agreement so a delayed real
            // release is filtered there instead of double-firing here.
            HotkeyMonitor.shared.resetPressState()
        }
    }

    private func cancelCurrentTurn() {
        guard let turn = currentTurn else { return }
        currentTurn = nil
        holdWatchdog?.invalidate()
        holdWatchdog = nil
        turn.streamer.stop()
        turn.transcriber.cancel()
        if Prefs.shared.playSounds { Sfx.nevermind?.play() }
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
            // Commit goes on the wire before the blocking engine teardown.
            turn.transcriber.commitAudio()
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
                // Long rambles need proportionally longer to flush — but a
                // runaway take must not pin "Transcribing…" for minutes.
                let timeout = min(60, max(12, turn.capturedSeconds * 0.4))
                text = try await turn.transcriber.finish(timeout: timeout)
            } catch is CancellationError {
                // fall through to batch
            } catch {
                failureMessage = error.localizedDescription
            }
        }

        if text == nil {
            // Realtime failed: the local buffer is the source of truth.
            // Park it on disk before anything that can still fail.
            let pcm = turn.captured
            if pcm.isEmpty {
                failureMessage = failureMessage ?? "no audio captured"
            } else {
                let saved = try? BatchTranscriber.savePending(pcm: pcm)
                if let apiKey = Prefs.shared.resolvedAPIKey() {
                    do {
                        text = try await BatchTranscriber.transcribe(
                            pcm: pcm, apiKey: apiKey, prompt: Self.batchPrompt(),
                            language: Prefs.shared.languageList.first)
                        if let saved { try? FileManager.default.removeItem(at: saved) }
                        failureMessage = nil
                    } catch {
                        failureMessage = "\(error.localizedDescription) — audio saved, recovered to history on next launch"
                    }
                } else {
                    failureMessage = "no API key — audio saved, recovered to history on next launch"
                }
            }
        }

        finalizingCount -= 1

        if let text {
            if text.isEmpty {
                // A failed capture is not a dictation; keep it out of the
                // history and the day stats.
                if turn.peak < Self.silenceFloor {
                    fail("No audio reached the app — check your input device")
                } else {
                    if Prefs.shared.playSounds { Sfx.nevermind?.play() }
                    settlePhase()
                }
            } else {
                // Paste first; bookkeeping and @Published churn after.
                deliver(text)
                recordEntry(text, turn: turn, releasedAt: releasedAt)
                settlePhase()
            }
        } else if let failureMessage {
            fail(failureMessage)
        } else {
            settlePhase()
        }
    }

    private func recordEntry(_ text: String, turn: DictationTurn, releasedAt: Date) {
        lastTranscript = text
        History.shared.add(text: text, seconds: turn.capturedSeconds,
                           finalizeSeconds: Date().timeIntervalSince(releasedAt),
                           truncated: turn.transcriber.timedOutWithPartial)
    }

    /// Recover WAVs parked by failed turns from previous runs: transcribe
    /// them into history (never paste — focus is unpredictable at launch,
    /// and lastTranscript stays owned by this session's dictations).
    func recoverPendingAudio() async {
        guard let apiKey = Prefs.shared.resolvedAPIKey() else { return }
        for url in BatchTranscriber.pendingFiles() {
            guard let text = try? await BatchTranscriber.transcribe(
                fileURL: url, apiKey: apiKey, prompt: Self.batchPrompt(),
                language: Prefs.shared.languageList.first) else { continue }
            History.shared.add(text: text, seconds: BatchTranscriber.duration(of: url))
            try? FileManager.default.removeItem(at: url)
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
        pendingPastes.append(Prefs.shared.trailingSpace ? text + " " : text)
        flushPendingPastes()
    }

    /// True when the hotkey's modifier is physically down right now.
    /// A synthesized ⌘V posted then would reach the app as ⌥⌘V.
    private var hotkeyPhysicallyDown: Bool {
        let flag = Prefs.shared.hotkey.cgEventFlag
        guard flag != [] else { return false }
        return CGEventSource.flagsState(.combinedSessionState).contains(flag)
    }

    private func flushPendingPastes() {
        guard !pendingPastes.isEmpty, currentTurn == nil, !hotkeyPhysicallyDown else { return }
        // One combined paste: N rapid-fire synthesized ⌘Vs race slow targets
        // into pasting the last payload twice and losing the first.
        let combined = pendingPastes.joined()
        pendingPastes.removeAll()
        if Paster.insertText(combined) {
            if Prefs.shared.playSounds && Prefs.shared.endSound {
                Sfx.landed?.play()
            }
        } else {
            fail("Secure input is active — the transcript is on your clipboard, press ⌘V")
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
            if Prefs.shared.playSounds { Sfx.trouble?.play() }
            return
        }
        phase = .error(message)
        if Prefs.shared.playSounds { Sfx.trouble?.play() }
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
