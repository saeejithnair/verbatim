import Foundation

/// One dictation turn against the Realtime transcription API
/// (wss://api.openai.com/v1/realtime?intent=transcription, model
/// gpt-live-transcribe). Create, connect(), append() audio while the key is
/// held, then finish() to commit and await the final transcript. One instance
/// per turn.
final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let queue = DispatchQueue(label: "verbatim.transcriber")

    /// Shared across turns so TLS session state is reused — repeat
    /// connections handshake noticeably faster than cold ones.
    private static let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?

    private var socketOpen = false
    private var socketClosed = false
    private var pendingAudio: [Data] = []
    private var committed = false
    private var appendedBytes = 0

    private var itemOrder: [String] = []
    private var deltas: [String: String] = [:]
    private var finals: [String: String] = [:]
    private var fatalError: String?
    private var finishContinuation: CheckedContinuation<String, Error>?

    /// Fired once if the socket dies while recording (before finish());
    /// the caller still has the local audio buffer and can fall back to
    /// batch transcription.
    var onConnectionLost: (() -> Void)?

    /// True when finish() timed out and returned delta-assembled text — the
    /// transcript may be missing its tail and should be marked as partial.
    private(set) var timedOutWithPartial = false

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func connect() {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = Self.session.webSocketTask(with: request)
        task.delegate = self
        self.task = task
        receiveLoop(task)
        task.resume()
    }

    func append(_ audio: Data) {
        queue.async {
            if self.socketOpen {
                self.appendedBytes += audio.count
                self.sendJSON(["type": "input_audio_buffer.append",
                               "audio": audio.base64EncodedString()])
            } else if !self.socketClosed {
                self.appendedBytes += audio.count
                self.pendingAudio.append(audio)
            }
        }
    }

    /// Duration of audio streamed this turn, for cost accounting.
    var streamedSeconds: Double {
        queue.sync { Double(appendedBytes) / (24000.0 * 2.0) }
    }

    func finish(timeout: TimeInterval = 12) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.queue.async {
                if let fatal = self.fatalError {
                    cont.resume(throwing: VerbatimError.transcription(fatal))
                    self.teardown()
                    return
                }
                if self.socketClosed {
                    cont.resume(throwing: VerbatimError.transcription("connection closed"))
                    self.teardown()
                    return
                }
                self.finishContinuation = cont
                self.committed = true
                if self.socketOpen {
                    self.sendJSON(["type": "input_audio_buffer.commit"])
                }
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.timedOut()
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.finishContinuation?.resume(throwing: CancellationError())
            self.finishContinuation = nil
            self.teardown()
        }
    }

    // MARK: - Socket lifecycle (all on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async {
            self.socketOpen = true
            self.sendSessionUpdate()
            for chunk in self.pendingAudio {
                self.sendJSON(["type": "input_audio_buffer.append",
                               "audio": chunk.base64EncodedString()])
            }
            self.pendingAudio.removeAll()
            if self.committed {
                self.sendJSON(["type": "input_audio_buffer.commit"])
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code \(closeCode.rawValue)"
        queue.async { self.socketFailed("socket closed: \(detail)") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard error != nil || status >= 400 else { return }
        let detail: String
        switch status {
        case 401, 403: detail = "API key rejected — check it in Settings"
        case 429: detail = "rate limited by OpenAI"
        case 500...599: detail = "OpenAI outage (HTTP \(status))"
        default: detail = error?.localizedDescription ?? "connection failed"
        }
        queue.async { self.socketFailed(detail) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async { self.socketFailed(error.localizedDescription) }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.queue.async { self.handleEvent(text) }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.queue.async { self.handleEvent(text) }
                    }
                @unknown default:
                    break
                }
                self.receiveLoop(task)
            }
        }
    }

    private func sendSessionUpdate() {
        var transcription: [String: Any] = [
            "model": "gpt-live-transcribe",
            "delay": Prefs.shared.delay.rawValue,
        ]
        var prompt = Prefs.shared.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clause = Prefs.shared.languageClause {
            prompt = prompt.isEmpty ? clause : prompt + "\n" + clause
        }
        if !prompt.isEmpty { transcription["prompt"] = prompt }
        let keywords = Prefs.shared.keywordList
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        let languages = Prefs.shared.languageList
        if !languages.isEmpty { transcription["languages"] = languages }

        sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": transcription,
                        // Push-to-talk: the hotkey release commits the turn.
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ])
    }

    private func handleEvent(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let id = object["item_id"] as? String {
                noteItem(id)
                deltas[id, default: ""] += object["delta"] as? String ?? ""
            }

        case "conversation.item.input_audio_transcription.completed":
            if let id = object["item_id"] as? String {
                noteItem(id)
                finals[id] = object["transcript"] as? String ?? ""
            }
            maybeComplete()

        case "error":
            let errorObject = object["error"] as? [String: Any]
            let message = (errorObject?["message"] as? String) ?? text
            let code = (errorObject?["code"] as? String) ?? ""
            // Committing a near-empty buffer (tap-and-release) errors; that is
            // just an empty dictation, not a failure. Match the code first —
            // the message wording is not a contract.
            if committed && (code == "input_audio_buffer_commit_empty"
                             || message.lowercased().contains("buffer")) {
                complete(.success(currentText()))
            } else if finishContinuation != nil {
                complete(.failure(VerbatimError.transcription(message)))
            } else {
                fatalError = message
            }

        default:
            break
        }
    }

    private func noteItem(_ id: String) {
        if !itemOrder.contains(id) { itemOrder.append(id) }
    }

    private func maybeComplete() {
        guard committed, !itemOrder.isEmpty,
              itemOrder.allSatisfy({ finals[$0] != nil }) else { return }
        complete(.success(currentText()))
    }

    private func currentText() -> String {
        itemOrder
            .compactMap { finals[$0] ?? deltas[$0] }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timedOut() {
        guard finishContinuation != nil else { return }
        let text = currentText()
        if text.isEmpty {
            complete(.failure(fatalError.map { VerbatimError.transcription($0) } ?? .timeout))
        } else {
            // Better a delta-built transcript than nothing — but flag it.
            timedOutWithPartial = true
            complete(.success(text))
        }
    }

    private func socketFailed(_ detail: String) {
        let firstFailure = !socketClosed
        socketOpen = false
        socketClosed = true
        guard finishContinuation != nil else {
            if fatalError == nil { fatalError = detail }
            if firstFailure { onConnectionLost?() }
            return
        }
        let text = currentText()
        if committed && !text.isEmpty {
            complete(.success(text))
        } else {
            complete(.failure(VerbatimError.transcription(fatalError ?? detail)))
        }
    }

    private func complete(_ result: Result<String, VerbatimError>) {
        guard let cont = finishContinuation else { return }
        finishContinuation = nil
        switch result {
        case .success(let text): cont.resume(returning: text)
        case .failure(let error): cont.resume(throwing: error)
        }
        teardown()
    }

    private func teardown() {
        socketOpen = false
        socketClosed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.queue.async { self?.socketFailed(error.localizedDescription) }
            }
        }
    }
}
