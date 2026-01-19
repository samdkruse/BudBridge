import AVFoundation
import Accelerate

class AudioManager: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var outputNode: AVAudioOutputNode?
    private var mixerNode: AVAudioMixerNode?

    @Published var isRunning = false
    @Published var inputLevel: Float = 0

    // Callback when mic audio is captured (send to network)
    var onAudioCaptured: ((Data) -> Void)?

    // Audio format: 16-bit PCM, 48kHz, mono
    private let sampleRate: Double = 48000
    private let channels: AVAudioChannelCount = 1

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
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
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
        guard !isRunning else { return }

        try configureAudioSession()

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        inputNode = engine.inputNode
        outputNode = engine.outputNode

        // Create mixer for playback
        mixerNode = AVAudioMixerNode()
        guard let mixer = mixerNode else { return }
        engine.attach(mixer)

        // Connect mixer to output
        let outputFormat = outputNode!.inputFormat(forBus: 0)
        engine.connect(mixer, to: outputNode!, format: outputFormat)

        // Tap input for mic capture
        let inputFormat = inputNode!.outputFormat(forBus: 0)
        inputNode!.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.processMicInput(buffer: buffer)
        }

        try engine.start()

        DispatchQueue.main.async {
            self.isRunning = true
        }

        print("Audio engine started")
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(false)

        DispatchQueue.main.async {
            self.isRunning = false
            self.inputLevel = 0
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

        onAudioCaptured?(pcmData)
    }

    // MARK: - Playback (from network)

    func playAudio(data: Data) {
        guard isRunning,
              let engine = audioEngine,
              let mixer = mixerNode,
              let format = pcmFormat else { return }

        let frameCount = AVAudioFrameCount(data.count / 2) // 16-bit = 2 bytes per sample
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy PCM data to buffer
        data.withUnsafeBytes { ptr in
            if let samples = ptr.bindMemory(to: Int16.self).baseAddress {
                for i in 0..<Int(frameCount) {
                    pcmBuffer.int16ChannelData?[0][i] = samples[i]
                }
            }
        }

        // Convert to float format for mixer
        guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frameCount) else { return }

        floatBuffer.frameLength = frameCount

        // Convert int16 to float
        if let intData = pcmBuffer.int16ChannelData?[0],
           let floatData = floatBuffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                floatData[i] = Float(intData[i]) / 32768.0
            }
        }

        // Schedule playback
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixer, format: floatFormat)

        playerNode.scheduleBuffer(floatBuffer) {
            DispatchQueue.main.async {
                engine.detach(playerNode)
            }
        }

        playerNode.play()
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

        print("Audio route changed: \(reason)")

        // Restart engine if needed after route change
        if isRunning {
            stop()
            try? start()
        }
    }
}
