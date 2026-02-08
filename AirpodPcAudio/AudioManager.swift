import AVFoundation
import Accelerate

class AudioManager: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?

    @Published var isRunning = false
    @Published var inputLevel: Float = 0
    @Published var pcAudioLevel: Float = 0

    // Callback when mic audio is captured (send to network)
    var onAudioCaptured: ((Data) -> Void)?

    // Audio format: 16-bit PCM, 48kHz, mono
    private let targetSampleRate: Double = 48000
    private let channels: AVAudioChannelCount = 1
    private var inputSampleRate: Double = 48000  // Actual mic sample rate (may differ due to HFP)

    // Debug stats
    private var playbackBufferCount = 0
    private var playbackSampleCount = 0
    private var captureBufferCount = 0
    private var captureSampleCount = 0
    private var lastAudioStatsTime = Date()

    // Low-latency jitter buffer (for receiving PC audio)
    private var jitterBuffer: [Float] = []
    private let jitterBufferLock = NSLock()
    private let maxBufferSamples: Int = 4800  // 100ms at 48kHz
    private let playbackChunkSize: Int = 960  // 20ms chunks
    private var playbackTimer: Timer?

    // Send buffer (for smoothing mic audio transmission)
    private var sendBuffer: [Int16] = []
    private let sendBufferLock = NSLock()
    private let sendChunkSize: Int = 960  // 20ms chunks at 48kHz
    private var sendTimer: Timer?

    // Track in-flight buffers to prevent unbounded queue growth
    private var scheduledBufferCount = 0
    private let scheduledBufferLock = NSLock()
    private let maxScheduledBuffers = 5  // Cap queued buffers in player node

    private var floatFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: channels, interleaved: false)
    }

    private var pcmFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: channels, interleaved: true)
    }

    init() {
        setupNotifications()
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio Session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )

        try session.setPreferredSampleRate(targetSampleRate)
        try session.setPreferredIOBufferDuration(0.005) // 5ms buffer for low latency
        try session.setActive(true)

        print("Audio session configured:")
        print("  Sample rate: \(session.sampleRate)")
        print("  Input channels: \(session.inputNumberOfChannels)")
        print("  Output channels: \(session.outputNumberOfChannels)")
        print("  IO buffer duration: \(session.ioBufferDuration)")
    }

    // MARK: - Audio Engine

    func start() throws {
        guard !isRunning else {
            print("⚠️ Audio engine already running")
            return
        }

        print("🔧 Configuring audio session...")
        try configureAudioSession()
        print("✅ Audio session configured")

        print("🔧 Creating audio engine...")
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            print("❌ Failed to create audio engine")
            return
        }

        inputNode = engine.inputNode
        print("🔧 Got input node")

        // Create persistent player node for playback
        playerNode = AVAudioPlayerNode()
        guard let player = playerNode, let format = floatFormat else {
            print("❌ Failed to create player or format")
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        print("🔧 Player connected to mixer")

        // Tap input for mic capture
        let inputFormat = inputNode!.outputFormat(forBus: 0)
        inputSampleRate = inputFormat.sampleRate
        print("🎤 Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        print("🔊 Target format: \(targetSampleRate) Hz (will resample if needed)")

        inputNode!.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.processMicInput(buffer: buffer)
        }
        print("🔧 Mic tap installed")

        print("🔧 Starting engine...")
        try engine.start()
        print("🔧 Engine started, starting player...")
        player.play()
        isRunning = true  // Set synchronously so playAudio works immediately
        print("▶️ Player started, isPlaying: \(player.isPlaying)")

        // Start timers for smooth audio I/O
        startPlaybackTimer()
        startSendTimer()
        print("✅ Audio engine fully started, isRunning = \(isRunning)")
    }

    func stop() {
        isRunning = false  // Set synchronously
        playbackTimer?.invalidate()
        playbackTimer = nil
        sendTimer?.invalidate()
        sendTimer = nil
        playerNode?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil

        // Clear buffers
        jitterBufferLock.lock()
        jitterBuffer.removeAll()
        jitterBufferLock.unlock()

        sendBufferLock.lock()
        sendBuffer.removeAll()
        sendBufferLock.unlock()

        // Reset scheduled buffer count
        scheduledBufferLock.lock()
        scheduledBufferCount = 0
        scheduledBufferLock.unlock()

        try? AVAudioSession.sharedInstance().setActive(false)

        DispatchQueue.main.async {
            self.inputLevel = 0
            self.pcAudioLevel = 0
        }

        print("Audio engine stopped")
    }

    // MARK: - Mic Input Processing

    private func processMicInput(buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // Calculate input level (RMS)
        var rms: Float = 0
        vDSP_rmsqv(floatData, 1, &rms, vDSP_Length(frameCount))
        DispatchQueue.main.async {
            self.inputLevel = rms
        }

        // Resample if needed (e.g., 24kHz HFP mic -> 48kHz target)
        let needsResampling = inputSampleRate != targetSampleRate && inputSampleRate > 0
        let outputCount: Int
        var resampledBuffer: [Float]?

        if needsResampling {
            let ratio = targetSampleRate / inputSampleRate
            outputCount = Int(Double(frameCount) * ratio)
            resampledBuffer = resample(floatData, inputCount: frameCount, outputCount: outputCount)
        } else {
            outputCount = frameCount
        }

        // Scale and convert to Int16 using vDSP
        var scaledSamples = [Float](repeating: 0, count: outputCount)
        var scale: Float = 32767.0

        if let resampled = resampledBuffer {
            vDSP_vsmul(resampled, 1, &scale, &scaledSamples, 1, vDSP_Length(outputCount))
        } else {
            vDSP_vsmul(floatData, 1, &scale, &scaledSamples, 1, vDSP_Length(outputCount))
        }

        // Clip and convert to Int16
        var minVal: Float = -32768.0
        var maxVal: Float = 32767.0
        vDSP_vclip(scaledSamples, 1, &minVal, &maxVal, &scaledSamples, 1, vDSP_Length(outputCount))

        var int16Samples = [Int16](repeating: 0, count: outputCount)
        vDSP_vfix16(scaledSamples, 1, &int16Samples, 1, vDSP_Length(outputCount))

        // Add to send buffer (will be drained by timer for smooth transmission)
        sendBufferLock.lock()
        sendBuffer.append(contentsOf: int16Samples)

        // Cap buffer size to prevent buildup (drop oldest if too large)
        let maxSendBuffer = 9600  // 200ms at 48kHz
        if sendBuffer.count > maxSendBuffer {
            sendBuffer.removeFirst(sendBuffer.count - maxSendBuffer)
        }
        sendBufferLock.unlock()

        captureBufferCount += 1
        captureSampleCount += outputCount
    }

    /// Linear interpolation resampling using vDSP (hardware accelerated)
    private func resample(_ input: UnsafePointer<Float>, inputCount: Int, outputCount: Int) -> [Float] {
        guard inputCount > 1, outputCount > 0 else {
            return Array(UnsafeBufferPointer(start: input, count: inputCount))
        }

        var output = [Float](repeating: 0, count: outputCount)

        // Generate interpolation indices
        var indices = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var step = Float(inputCount - 1) / Float(outputCount - 1)
        vDSP_vramp(&start, &step, &indices, 1, vDSP_Length(outputCount))

        // Perform linear interpolation using vDSP
        vDSP_vlint(input, &indices, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(inputCount))

        return output
    }

    // MARK: - Playback (from network)

    func playAudio(data: Data) {
        guard isRunning else {
            return
        }

        let frameCount = data.count / 2  // 16-bit = 2 bytes per sample
        guard frameCount > 0 else { return }

        // Convert to float samples directly into jitter buffer
        var rmsLevel: Float = 0

        jitterBufferLock.lock()
        let insertOffset = jitterBuffer.count
        jitterBuffer.append(contentsOf: repeatElement(Float(0), count: frameCount))

        data.withUnsafeBytes { ptr in
            if let samples = ptr.bindMemory(to: Int16.self).baseAddress {
                for i in 0..<frameCount {
                    jitterBuffer[insertOffset + i] = Float(samples[i]) / 32768.0
                }
                // Calculate RMS for level meter using the samples we just wrote
                jitterBuffer.withUnsafeBufferPointer { bufPtr in
                    if let base = bufPtr.baseAddress {
                        vDSP_rmsqv(base + insertOffset, 1, &rmsLevel, vDSP_Length(frameCount))
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.pcAudioLevel = rmsLevel
        }

        // If buffer exceeds max, drop oldest samples to stay at target latency
        if jitterBuffer.count > maxBufferSamples {
            let overflow = jitterBuffer.count - maxBufferSamples
            jitterBuffer.removeFirst(overflow)
        }

        playbackBufferCount += 1
        playbackSampleCount += frameCount

        // Log stats every second
        let now = Date()
        if now.timeIntervalSince(lastAudioStatsTime) >= 1.0 {
            let bufferMs = Int(Double(jitterBuffer.count) / targetSampleRate * 1000)
            print("🔊 Jitter buffer: \(jitterBuffer.count) samples (\(bufferMs)ms) | Received: \(playbackBufferCount) pkts, \(playbackSampleCount) samples")
            playbackBufferCount = 0
            playbackSampleCount = 0
            lastAudioStatsTime = now
        }
        jitterBufferLock.unlock()
    }

    // MARK: - Timer-based Playback

    private func startPlaybackTimer() {
        // Schedule playback every 20ms
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.drainJitterBuffer()
        }
    }

    private func drainJitterBuffer() {
        guard isRunning,
              let player = playerNode,
              let format = floatFormat else { return }

        // Don't queue more buffers if player already has enough
        scheduledBufferLock.lock()
        let currentCount = scheduledBufferCount
        scheduledBufferLock.unlock()
        guard currentCount < maxScheduledBuffers else { return }

        jitterBufferLock.lock()

        // Need at least one chunk to play
        guard jitterBuffer.count >= playbackChunkSize else {
            jitterBufferLock.unlock()
            return
        }

        // Extract one chunk
        let samples = Array(jitterBuffer.prefix(playbackChunkSize))
        jitterBuffer.removeFirst(playbackChunkSize)
        jitterBufferLock.unlock()

        // Create buffer and schedule
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(playbackChunkSize)) else { return }
        buffer.frameLength = AVAudioFrameCount(playbackChunkSize)

        if let floatData = buffer.floatChannelData?[0] {
            for i in 0..<playbackChunkSize {
                floatData[i] = samples[i]
            }
        }

        scheduledBufferLock.lock()
        scheduledBufferCount += 1
        scheduledBufferLock.unlock()

        player.scheduleBuffer(buffer) { [weak self] in
            self?.scheduledBufferLock.lock()
            self?.scheduledBufferCount -= 1
            self?.scheduledBufferLock.unlock()
        }
    }

    // MARK: - Timer-based Sending

    private func startSendTimer() {
        // Send mic audio every 20ms for smooth transmission
        sendTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.drainSendBuffer()
        }
    }

    private func drainSendBuffer() {
        guard isRunning else { return }

        sendBufferLock.lock()

        // Need at least one chunk to send
        guard sendBuffer.count >= sendChunkSize else {
            sendBufferLock.unlock()
            return
        }

        // Extract one chunk
        let samples = Array(sendBuffer.prefix(sendChunkSize))
        sendBuffer.removeFirst(sendChunkSize)
        sendBufferLock.unlock()

        // Convert to Data and send
        let pcmData = samples.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }

        onAudioCaptured?(pcmData)
    }

    // MARK: - Interruption Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("Audio interruption began")
            stop()
        case .ended:
            print("Audio interruption ended")
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    try? start()
                }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        print("Audio route changed: \(reason.rawValue)")

        // Only restart on meaningful route changes (device connected/disconnected)
        // Ignore categoryChange (3), override (4), wakeFromSleep (6), etc.
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            print("🔄 Restarting audio engine due to device change")
            if isRunning {
                stop()
                try? start()
            }
        default:
            // Don't restart for other reasons (category change, etc.)
            break
        }
    }
}
