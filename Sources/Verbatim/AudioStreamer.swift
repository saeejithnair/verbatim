import AVFoundation

/// Taps the default input device and emits 24 kHz mono PCM16 chunks, the
/// format the Realtime transcription API expects.
final class AudioStreamer {
    static let apiFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    var onChunk: ((Data) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inFormat, to: Self.apiFormat) else {
            throw VerbatimError.audioSetup("no usable input device")
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self,
                  let data = Self.convert(buffer, with: converter, to: Self.apiFormat),
                  !data.isEmpty else { return }
            self.onChunk?(data)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    static func convert(_ buffer: AVAudioPCMBuffer,
                        with converter: AVAudioConverter,
                        to outFormat: AVAudioFormat) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return nil
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else {
            return nil
        }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
