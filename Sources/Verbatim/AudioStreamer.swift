import AudioToolbox
import AVFoundation

/// Captures the input device as 24 kHz mono PCM16 chunks, the format the
/// Realtime transcription API expects.
///
/// An input-only AudioQueue, not AVAudioEngine: the engine runs input and
/// output through one duplex unit, so its input is bound to the OUTPUT
/// device — an AirPlay TV at 44.1 kHz against a 48 kHz mic fails to start
/// (-10868), and every output route change tears the tap down mid-take. The
/// queue never touches output, and it resamples to the API format itself.
final class AudioStreamer {
    static let apiFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    /// ~43 ms per chunk, three in flight.
    private static let bufferBytes: UInt32 = 2048
    private static let bufferCount = 3

    private var queue: AudioQueueRef?

    /// Converted PCM chunk plus its peak sample amplitude (for dead-mic
    /// detection). Called on a private serial queue.
    var onChunk: ((Data, Int16) -> Void)?

    func start() throws {
        var format = Self.apiFormat.streamDescription.pointee
        var newQueue: AudioQueueRef?
        try check(AudioQueueNewInputWithDispatchQueue(
            &newQueue, &format, 0, DispatchQueue(label: "ai.papiers.Verbatim.capture")
        ) { [weak self] queue, buffer, _, _, _ in
            let bytes = Int(buffer.pointee.mAudioDataByteSize)
            if bytes > 0, let self {
                let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
                var peak: Int16 = 0
                for i in 0..<bytes / MemoryLayout<Int16>.size {
                    let magnitude = Int16(clamping: abs(Int(samples[i])))
                    if magnitude > peak { peak = magnitude }
                }
                self.onChunk?(Data(bytes: samples, count: bytes), peak)
            }
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }, "create queue")
        guard let newQueue else { throw VerbatimError.audioSetup("no queue") }
        queue = newQueue

        do {
            // Pin the chosen input device; if it's gone, the queue records
            // from the system default.
            let pinnedName = Prefs.shared.inputDevice
            if !pinnedName.isEmpty {
                if let uid = AudioDevices.uid(named: pinnedName) {
                    var device = uid as CFString
                    try check(AudioQueueSetProperty(
                        newQueue, kAudioQueueProperty_CurrentDevice, &device,
                        UInt32(MemoryLayout<CFString>.size)), "pin '\(pinnedName)'")
                    NSLog("Verbatim: capturing from '%@'", pinnedName)
                } else {
                    NSLog("Verbatim: '%@' missing — capturing from system default", pinnedName)
                }
            }
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(newQueue, Self.bufferBytes, &buffer), "allocate")
                AudioQueueEnqueueBuffer(newQueue, buffer!, 0, nil)
            }
            try check(AudioQueueStart(newQueue, nil), "start")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let queue else { return }
        self.queue = nil
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
    }

    deinit {
        stop()
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw VerbatimError.audioSetup("\(step) failed (OSStatus \(status))")
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer,
                        with converter: AVAudioConverter,
                        to outFormat: AVAudioFormat) -> (data: Data, peak: Int16)? {
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
        let frames = Int(out.frameLength)
        var peak: Int16 = 0
        for i in 0..<frames {
            let magnitude = Int16(clamping: abs(Int(channel[0][i])))
            if magnitude > peak { peak = magnitude }
        }
        return (Data(bytes: channel[0], count: frames * MemoryLayout<Int16>.size), peak)
    }
}
