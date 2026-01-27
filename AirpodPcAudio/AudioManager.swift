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
    private let sampleRate: Double = 48000
    private let channels: AVAudioChannelCount = 1

    // Debug stats
    private var playbackBufferCount = 0
    private var playbackSampleCount = 0
    private var captureBufferCount = 0
    private var captureSampleCount = 0
    private var lastAudioStatsTime = Date()

    // Low-latency jitter buffer
    private var jitterBuffer: [Float] = []
    private let jitterBufferLock = NSLock()
    private let maxBufferSamples: Int = 4800  // 100ms at 48kHz
    private let playbackChunkSize: Int = 960  // 20ms chunks
    private var playbackTimer: Timer?

    private var floatFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
    }

    private var pcmFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)
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

        try session.setPreferredSampleRate(sampleRate)
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
        print("🎤 Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, \(inputFormat.commonFormat.rawValue)")
        print("🔊 Output format: \(format.sampleRate) Hz, \(format.channelCount) ch")

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

        // Start timer to drain jitter buffer at regular intervals
        startPlaybackTimer()
        print("✅ Audio engine fully started, isRunning = \(isRunning)")
    }

    func stop() {
        isRunning = false  // Set synchronously
        playbackTimer?.invalidate()
        playbackTimer = nil
        playerNode?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil

        // Clear jitter buffer
        jitterBufferLock.lock()
        jitterBuffer.removeAll()
        jitterBufferLock.unlock()

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

        // Convert float to 16-bit PCM
        var pcmData = Data(capacity: frameCount * 2)
        for i in 0..<frameCount {
            let sample = max(-1, min(1, floatData[i]))
            var intSample = Int16(sample * 32767)
            pcmData.append(Data(bytes: &intSample, count: 2))
        }

        captureBufferCount += 1
        captureSampleCount += frameCount

        onAudioCaptured?(pcmData)
    }

    // MARK: - Playback (from network)

    func playAudio(data: Data) {
        guard isRunning else {
            return
        }

        let frameCount = data.count / 2  // 16-bit = 2 bytes per sample
        guard frameCount > 0 else { return }

        // Convert to float samples
        var floatSamples = [Float](repeating: 0, count: frameCount)
        var rmsLevel: Float = 0

        data.withUnsafeBytes { ptr in
            if let samples = ptr.bindMemory(to: Int16.self).baseAddress {
                for i in 0..<frameCount {
                    floatSamples[i] = Float(samples[i]) / 32768.0
                }
                // Calculate RMS for level meter
                vDSP_rmsqv(floatSamples, 1, &rmsLevel, vDSP_Length(frameCount))
            }
        }

        DispatchQueue.main.async {
            self.pcAudioLevel = rmsLevel
        }

        // Add to jitter buffer (drop oldest if full)
        jitterBufferLock.lock()
        jitterBuffer.append(contentsOf: floatSamples)

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
            let bufferMs = Int(Double(jitterBuffer.count) / sampleRate * 1000)
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

        player.scheduleBuffer(buffer, completionHandler: nil)
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
