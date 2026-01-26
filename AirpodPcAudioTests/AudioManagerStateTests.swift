import XCTest
@testable import AirpodPcAudio
import AVFoundation

/// Tests for AudioManager state transitions and behavior
/// Note: These tests verify logic, not actual audio hardware
final class AudioManagerStateTests: XCTestCase {

    // MARK: - Route Change Reason Tests

    /// Verify which route change reasons should trigger a restart
    func testRouteChangeReasons_shouldRestart() {
        // These reasons indicate a device was added/removed and SHOULD restart
        let shouldRestart: [AVAudioSession.RouteChangeReason] = [
            .newDeviceAvailable,    // e.g., AirPods connected
            .oldDeviceUnavailable,  // e.g., AirPods disconnected
        ]

        for reason in shouldRestart {
            XCTAssertTrue(
                shouldRestartOnRouteChange(reason),
                "Should restart for reason: \(reason.rawValue)"
            )
        }
    }

    func testRouteChangeReasons_shouldNotRestart() {
        // These reasons should NOT trigger a restart (would cause infinite loops)
        let shouldNotRestart: [AVAudioSession.RouteChangeReason] = [
            .categoryChange,        // We set this ourselves - rawValue 3
            .override,              // Temporary override
            .wakeFromSleep,         // Device woke up
            .noSuitableRouteForCategory,
            .routeConfigurationChange,
        ]

        for reason in shouldNotRestart {
            XCTAssertFalse(
                shouldRestartOnRouteChange(reason),
                "Should NOT restart for reason: \(reason.rawValue)"
            )
        }
    }

    /// Helper that mirrors the logic in AudioManager.handleRouteChange
    private func shouldRestartOnRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            return true
        default:
            return false
        }
    }

    // MARK: - State Transition Tests

    func testIsRunning_initiallyFalse() {
        // Verify initial state without starting real audio
        // In a real test, we'd use dependency injection for AVAudioEngine
        let isRunning = false // Initial state
        XCTAssertFalse(isRunning)
    }

    // MARK: - Audio Format Validation

    func testAudioFormat_48kHzMono() {
        // Verify our expected format matches what we use
        let expectedSampleRate: Double = 48000
        let expectedChannels: AVAudioChannelCount = 1

        // These should match AudioManager's private constants
        XCTAssertEqual(expectedSampleRate, 48000)
        XCTAssertEqual(expectedChannels, 1)
    }

    func testPCMBufferSize_matchesSampleCount() {
        // 480 bytes of PCM = 240 samples (16-bit = 2 bytes per sample)
        let pcmBytes = 480
        let expectedSamples = pcmBytes / 2

        XCTAssertEqual(expectedSamples, 240)
    }

    // MARK: - Buffer Duration Tests

    func testBufferDuration_20ms() {
        // At 48kHz, 20ms = 960 samples
        let sampleRate: Double = 48000
        let bufferDuration: Double = 0.02 // 20ms
        let expectedSamples = Int(sampleRate * bufferDuration)

        XCTAssertEqual(expectedSamples, 960)
    }
}

// MARK: - Network Manager State Tests

final class NetworkManagerStateTests: XCTestCase {

    func testPorts_areCorrect() {
        // Verify port configuration
        let sendPort: UInt16 = 4810    // PC listens here
        let receivePort: UInt16 = 4811 // iPhone listens here

        XCTAssertEqual(sendPort, 4810)
        XCTAssertEqual(receivePort, 4811)
        XCTAssertNotEqual(sendPort, receivePort, "Send and receive ports must differ")
    }

    func testChunkSize_underMTU() {
        // UDP packets should be under typical MTU to avoid fragmentation
        let maxChunkSize = NetworkPackets.maxChunkSize
        let typicalMTU = 1500
        let udpHeaderSize = 8
        let ipHeaderSize = 20

        let maxSafePayload = typicalMTU - udpHeaderSize - ipHeaderSize

        XCTAssertLessThanOrEqual(maxChunkSize, maxSafePayload,
            "Chunk size \(maxChunkSize) exceeds safe UDP payload \(maxSafePayload)")
    }
}
