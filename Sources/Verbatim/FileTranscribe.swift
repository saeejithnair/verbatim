import AVFoundation
import Foundation

/// Headless pipeline test: stream an audio file through the realtime engine
/// exactly as the mic path would, print the transcript, exit.
func transcribeFileAndExit(path: String) {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let text = try await transcribeFile(path: path)
            print(text)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    exit(exitCode)
}

private func transcribeFile(path: String) async throws -> String {
    guard let apiKey = Prefs.shared.resolvedAPIKey() else {
        throw VerbatimError.missingAPIKey
    }

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    guard let converter = AVAudioConverter(from: inFormat, to: AudioStreamer.apiFormat) else {
        throw VerbatimError.audioSetup("cannot convert \(inFormat)")
    }

    let transcriber = RealtimeTranscriber(apiKey: apiKey)
    transcriber.connect()

    let chunkFrames = AVAudioFrameCount(inFormat.sampleRate / 10)  // ~100 ms
    // Reading past EOF throws (macOS 26), so never request more than remains.
    while file.framePosition < file.length {
        let remaining = AVAudioFrameCount(file.length - file.framePosition)
        let want = min(chunkFrames, remaining)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: want) else {
            throw VerbatimError.audioSetup("buffer allocation failed")
        }
        try file.read(into: buffer, frameCount: want)
        if buffer.frameLength == 0 { break }
        if let chunk = AudioStreamer.convert(buffer, with: converter, to: AudioStreamer.apiFormat) {
            transcriber.append(chunk.data)
        }
    }

    return try await transcriber.finish(timeout: 30)
}
