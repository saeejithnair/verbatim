import AudioToolbox
import AVFoundation
import ObjCTry

/// Taps the default input device and emits 24 kHz mono PCM16 chunks, the
/// format the Realtime transcription API expects.
///
/// Route changes (AirPlay/TV connect, AirPods, device switches) are the
/// hazard here: the engine stops itself and AVFoundation raises uncatchable
/// NSExceptions if a tap is installed while the input format is transiently
/// invalid — that crashed a live demo. Every exception-capable AVFoundation
/// call goes through the ObjCTry shim, so the worst case is a thrown Swift
/// error and a retry, never a crash.
final class AudioStreamer {
    static let apiFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var pendingRetry: DispatchWorkItem?
    private var stopped = false

    /// Converted PCM chunk plus its peak sample amplitude (for dead-mic
    /// detection).
    var onChunk: ((Data, Int16) -> Void)?

    func start() throws {
        try installTap()
        // AirPods connecting, default-device switches, etc. reconfigure the
        // engine underneath the tap; reinstall so the stream survives.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // removeObserver doesn't cancel an already-enqueued block; a
            // config change landing at key release must not resurrect the
            // tap (and the orange mic light) after stop().
            guard let self, !self.stopped else { return }
            self.attemptReinstall()
        }
    }

    /// Reinstall immediately — the engine stopped itself on the config
    /// change, so every millisecond before the tap is back is lost speech.
    /// NSExceptions are converted to Swift errors by the ObjC shim, so a
    /// mid-burst attempt against an invalid format fails softly and retries.
    private func attemptReinstall() {
        pendingRetry?.cancel()
        pendingRetry = nil
        guard !stopped else { return }
        do {
            try installTap()
        } catch {
            NSLog("Verbatim: tap reinstall failed (%@) — retrying in 250 ms",
                  error.localizedDescription)
            let work = DispatchWorkItem { [weak self] in self?.attemptReinstall() }
            pendingRetry = work
            // Self-rearming until it succeeds or the turn stops — a failure
            // on the burst's last notification must not strand a dead mic.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func installTap() throws {
        engine.inputNode.removeTap(onBus: 0)
        let input = engine.inputNode

        // Pin the chosen input device (falls back to system default if it's
        // gone). Must happen before the format is read.
        let pinnedName = Prefs.shared.inputDevice
        if !pinnedName.isEmpty {
            if var deviceID = AudioDevices.device(named: pinnedName),
               let audioUnit = input.audioUnit {
                let status = AudioUnitSetProperty(
                    audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                NSLog("Verbatim: pin '%@' status %d", pinnedName, status)
            } else {
                NSLog("Verbatim: pin '%@' failed — device or audio unit missing", pinnedName)
            }
        }
        // Read back which device the input is actually using.
        if let audioUnit = input.audioUnit {
            var actualID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &actualID, &size) == noErr {
                NSLog("Verbatim: capturing from '%@'",
                      AudioDevices.deviceName(actualID) ?? "device \(actualID)")
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        // sampleRate alone is not enough: mid-route-change the node can
        // report a valid rate with ZERO channels.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: Self.apiFormat) else {
            throw VerbatimError.audioSetup("no usable input device")
        }

        // format: nil — tap in whatever the node's CURRENT format is, so a
        // format that went stale between reading it and installing can't be
        // handed to AVFoundation. The converter is block-local and rebuilt
        // if the buffer format drifts mid-take (route change while talking).
        var blockConverter = converter
        var loggedRebuildFailure = false
        let tapBlock: (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let self else { return }
            if blockConverter.inputFormat != buffer.format {
                guard let fresh = AVAudioConverter(from: buffer.format, to: Self.apiFormat) else {
                    if !loggedRebuildFailure {
                        loggedRebuildFailure = true
                        NSLog("Verbatim: no converter for drifted format %@", buffer.format)
                    }
                    return
                }
                blockConverter = fresh
            }
            guard let chunk = Self.convert(buffer, with: blockConverter, to: Self.apiFormat),
                  !chunk.data.isEmpty else { return }
            self.onChunk?(chunk.data, chunk.peak)
        }

        // The guard above is a snapshot; the HAL can invalidate the format
        // between it and this call, and installTap answers that with an
        // NSException. The shim turns it into a throw (→ retry), not a crash.
        if let exception = VBTryCatch({
            input.installTap(onBus: 0, bufferSize: 2048, format: nil, block: tapBlock)
            self.engine.prepare()
        }) {
            throw VerbatimError.audioSetup(
                "tap rejected: \(exception.reason ?? exception.name.rawValue)")
        }

        if !engine.isRunning {
            var startError: Error?
            if let exception = VBTryCatch({
                do { try self.engine.start() } catch { startError = error }
            }) {
                throw VerbatimError.audioSetup(
                    "engine start rejected: \(exception.reason ?? exception.name.rawValue)")
            }
            if let startError { throw startError }
        }
    }

    func stop() {
        stopped = true
        pendingRetry?.cancel()
        pendingRetry = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit {
        // Backstop for any future path that drops a streamer without stop():
        // the observer registration and armed retry must not outlive us.
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        pendingRetry?.cancel()
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
