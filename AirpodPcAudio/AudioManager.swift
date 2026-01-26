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
        try session.setPreferredIOBufferDuration(0.02) // 20ms buffer
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
        print("✅ Audio engine fully started, isRunning = \(isRunning)")
    }

    func stop() {
        isRunning = false  // Set synchronously
        playerNode?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil

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
        guard isRunning,
              let player = playerNode,
              let format = floatFormat else {
            if !isRunning {
                print("🔇 playAudio called but engine not running")
            }
            return
        }

        let frameCount = AVAudioFrameCount(data.count / 2) // 16-bit = 2 bytes per sample
        guard frameCount > 0,
              let floatBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        floatBuffer.frameLength = frameCount

        // Convert to float and calculate RMS level
        var maxAmp: Int16 = 0
        var nonZero = 0
        var rmsLevel: Float = 0
        data.withUnsafeBytes { ptr in
            if let samples = ptr.bindMemory(to: Int16.self).baseAddress,
               let floatData = floatBuffer.floatChannelData?[0] {
                for i in 0..<Int(frameCount) {
                    let sample = samples[i]
                    floatData[i] = Float(sample) / 32768.0
                    if sample != 0 {
                        nonZero += 1
                        if abs(sample) > abs(maxAmp) { maxAmp = sample }
                    }
                }
                // Calculate RMS for level meter
                vDSP_rmsqv(floatData, 1, &rmsLevel, vDSP_Length(frameCount))
            }
        }

        DispatchQueue.main.async {
            self.pcAudioLevel = rmsLevel
        }

        playbackBufferCount += 1
        playbackSampleCount += Int(frameCount)

        // Log playback stats every second
        let now = Date()
        if now.timeIntervalSince(lastAudioStatsTime) >= 1.0 {
            print("🔊 Playback: \(playbackBufferCount) buffers, \(playbackSampleCount) samples | Player playing: \(player.isPlaying)")
            print("   Last buffer: \(frameCount) samples, \(nonZero) non-zero, maxAmp: \(maxAmp)")
            playbackBufferCount = 0
            playbackSampleCount = 0
            lastAudioStatsTime = now
        }

        // Schedule buffer on persistent player node
        player.scheduleBuffer(floatBuffer, completionHandler: nil)
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
