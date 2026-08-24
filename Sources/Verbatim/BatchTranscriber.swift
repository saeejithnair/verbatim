import Foundation

/// Fallback path when the realtime socket fails: the locally buffered PCM is
/// wrapped in a WAV and sent to the batch transcription endpoint. Audio that
/// can't be transcribed right now is parked in Application
/// Support/Verbatim/pending/ and recovered into history on next launch.
enum BatchTranscriber {
    private static let models = ["gpt-transcribe", "gpt-4o-transcribe"]

    static let pendingDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbatim/pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func savePending(pcm: Data) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Uniquified: two turns failing in the same second must not
        // overwrite each other — this file is the last copy of the words.
        let name = "turn-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).wav"
        let url = pendingDir.appendingPathComponent(name)
        try wav(from: pcm).write(to: url)
        return url
    }

    static func pendingFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// Seconds of audio in a pending WAV (24 kHz mono 16-bit + 44-byte header).
    static func duration(of url: URL) -> Double {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? Int) ?? 44
        return Double(max(0, bytes - 44)) / 48_000.0
    }

    static func transcribe(pcm: Data, apiKey: String, prompt: String,
                           language: String? = nil) async throws -> String {
        try await transcribe(wavData: wav(from: pcm), apiKey: apiKey, prompt: prompt, language: language)
    }

    static func transcribe(fileURL: URL, apiKey: String, prompt: String,
                           language: String? = nil) async throws -> String {
        try await transcribe(wavData: try Data(contentsOf: fileURL), apiKey: apiKey,
                             prompt: prompt, language: language)
    }

    // Language arrives as a parameter: this runs off the main actor, and
    // Prefs is main-thread UI state.
    private static func transcribe(wavData: Data, apiKey: String, prompt: String,
                                   language: String?) async throws -> String {
        var lastError: Error = VerbatimError.transcription("batch transcription failed")
        for model in models {
            do {
                return try await upload(wavData: wavData, model: model, apiKey: apiKey,
                                        prompt: prompt, language: language)
            } catch let error as ModelUnavailable {
                lastError = VerbatimError.transcription(error.message)
            }
        }
        throw lastError
    }

    private struct ModelUnavailable: Error {
        let message: String
    }

    private static func upload(wavData: Data, model: String, apiKey: String,
                               prompt: String, language: String? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "verbatim-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.reserveCapacity(wavData.count + 2048)
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        if !prompt.isEmpty { field("prompt", prompt) }
        if let language, !language.isEmpty { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if (200..<300).contains(status), let text = object?["text"] as? String {
            return text
        }
        let apiMessage = (object?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 404:
            // Model gone or renamed — the only case where trying the next
            // model in the fallback list makes sense.
            throw ModelUnavailable(message: apiMessage ?? "model \(model) unavailable")
        case 401, 403:
            throw VerbatimError.transcription("API key rejected — check it in Settings")
        case 429:
            throw VerbatimError.transcription("rate limited by OpenAI")
        case 500...599:
            throw VerbatimError.transcription("OpenAI outage (HTTP \(status))")
        default:
            throw VerbatimError.transcription(apiMessage ?? "batch transcription failed (HTTP \(status))")
        }
    }

    /// 24 kHz mono 16-bit PCM → WAV.
    static func wav(from pcm: Data) -> Data {
        let sampleRate: UInt32 = 24_000
        let byteRate = sampleRate * 2
        var data = Data()
        data.reserveCapacity(44 + pcm.count)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); append32(UInt32(36 + pcm.count)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(byteRate); append16(2); append16(16)
        data.append(Data("data".utf8)); append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
