import XCTest
@testable import AirpodPcAudio

final class AudioConversionTests: XCTestCase {

    // MARK: - PCM to Float Conversion

    func testPCMToFloat_silence() {
        // Silence = all zeros
        let pcmData = Data([0x00, 0x00, 0x00, 0x00])
        let result = AudioConversion.pcmToFloat(pcmData)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.0, accuracy: 0.0001)
    }

    func testPCMToFloat_maxPositive() {
        // 0x7FFF = 32767 = max positive Int16
        let pcmData = Data([0xFF, 0x7F])
        let result = AudioConversion.pcmToFloat(pcmData)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 32767.0 / 32768.0, accuracy: 0.0001)
        XCTAssertLessThan(result[0], 1.0) // Should be just under 1.0
    }

    func testPCMToFloat_maxNegative() {
        // 0x8000 = -32768 = min Int16
        let pcmData = Data([0x00, 0x80])
        let result = AudioConversion.pcmToFloat(pcmData)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], -1.0, accuracy: 0.0001)
    }

    func testPCMToFloat_midPositive() {
        // 0x4000 = 16384 = half max
        let pcmData = Data([0x00, 0x40])
        let result = AudioConversion.pcmToFloat(pcmData)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 0.5, accuracy: 0.001)
    }

    func testPCMToFloat_emptyData() {
        let pcmData = Data()
        let result = AudioConversion.pcmToFloat(pcmData)

        XCTAssertEqual(result.count, 0)
    }

    // MARK: - Float to PCM Conversion

    func testFloatToPCM_silence() {
        let samples: [Float] = [0.0, 0.0]

        let result = samples.withUnsafeBufferPointer { ptr in
            AudioConversion.floatToPCM(ptr.baseAddress!, count: samples.count)
        }

        XCTAssertEqual(result.count, 4) // 2 samples * 2 bytes
        XCTAssertEqual(result[0], 0x00)
        XCTAssertEqual(result[1], 0x00)
    }

    func testFloatToPCM_maxPositive() {
        let samples: [Float] = [1.0]

        let result = samples.withUnsafeBufferPointer { ptr in
            AudioConversion.floatToPCM(ptr.baseAddress!, count: samples.count)
        }

        // Should clamp to 32767 (0x7FFF)
        XCTAssertEqual(result[0], 0xFF)
        XCTAssertEqual(result[1], 0x7F)
    }

    func testFloatToPCM_clipsOverflow() {
        // Values > 1.0 should be clipped to 1.0
        let samples: [Float] = [1.5]

        let result = samples.withUnsafeBufferPointer { ptr in
            AudioConversion.floatToPCM(ptr.baseAddress!, count: samples.count)
        }

        // Should clamp to 32767 (0x7FFF), not overflow
        XCTAssertEqual(result[0], 0xFF)
        XCTAssertEqual(result[1], 0x7F)
    }

    func testFloatToPCM_clipsUnderflow() {
        // Values < -1.0 should be clipped to -1.0
        let samples: [Float] = [-1.5]

        let result = samples.withUnsafeBufferPointer { ptr in
            AudioConversion.floatToPCM(ptr.baseAddress!, count: samples.count)
        }

        // Should clamp to -32767 (0x8001), not underflow
        // Note: -1.0 * 32767 = -32767, not -32768
        let value = Int16(bitPattern: UInt16(result[0]) | (UInt16(result[1]) << 8))
        XCTAssertEqual(value, -32767)
    }

    // MARK: - RMS Calculation

    func testCalculateRMS_silence() {
        let samples: [Float] = [0.0, 0.0, 0.0, 0.0]
        let rms = AudioConversion.calculateRMS(samples)

        XCTAssertEqual(rms, 0.0, accuracy: 0.0001)
    }

    func testCalculateRMS_constantSignal() {
        // RMS of constant signal should equal the absolute value
        let samples: [Float] = [0.5, 0.5, 0.5, 0.5]
        let rms = AudioConversion.calculateRMS(samples)

        XCTAssertEqual(rms, 0.5, accuracy: 0.0001)
    }

    func testCalculateRMS_sineWave() {
        // RMS of a full sine wave cycle should be ~0.707 of peak
        let samples: [Float] = [0, 0.707, 1.0, 0.707, 0, -0.707, -1.0, -0.707]
        let rms = AudioConversion.calculateRMS(samples)

        // Expected RMS ≈ 0.707
        XCTAssertEqual(rms, 0.707, accuracy: 0.05)
    }

    func testCalculateRMS_empty() {
        let samples: [Float] = []
        let rms = AudioConversion.calculateRMS(samples)

        XCTAssertEqual(rms, 0.0)
    }

    // MARK: - Audio Analysis

    func testAnalyzeAudio_allSilence() {
        let pcmData = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let (nonZero, maxAmp) = AudioConversion.analyzeAudio(pcmData)

        XCTAssertEqual(nonZero, 0)
        XCTAssertEqual(maxAmp, 0)
    }

    func testAnalyzeAudio_mixedSignal() {
        // Three samples: 0, 100, -200
        var data = Data()
        var s1: Int16 = 0
        var s2: Int16 = 100
        var s3: Int16 = -200
        data.append(Data(bytes: &s1, count: 2))
        data.append(Data(bytes: &s2, count: 2))
        data.append(Data(bytes: &s3, count: 2))

        let (nonZero, maxAmp) = AudioConversion.analyzeAudio(data)

        XCTAssertEqual(nonZero, 2) // Two non-zero samples
        XCTAssertEqual(maxAmp, -200) // -200 has larger absolute value
    }

    // MARK: - Network Chunking

    func testChunk_smallData() {
        let data = Data(repeating: 0xAB, count: 100)
        let chunks = NetworkPackets.chunk(data)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 100)
    }

    func testChunk_exactlyMaxSize() {
        let data = Data(repeating: 0xAB, count: NetworkPackets.maxChunkSize)
        let chunks = NetworkPackets.chunk(data)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, NetworkPackets.maxChunkSize)
    }

    func testChunk_slightlyOverMaxSize() {
        let data = Data(repeating: 0xAB, count: NetworkPackets.maxChunkSize + 1)
        let chunks = NetworkPackets.chunk(data)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, NetworkPackets.maxChunkSize)
        XCTAssertEqual(chunks[1].count, 1)
    }

    func testChunk_multipleChunks() {
        let data = Data(repeating: 0xAB, count: NetworkPackets.maxChunkSize * 3 + 500)
        let chunks = NetworkPackets.chunk(data)

        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].count, NetworkPackets.maxChunkSize)
        XCTAssertEqual(chunks[1].count, NetworkPackets.maxChunkSize)
        XCTAssertEqual(chunks[2].count, NetworkPackets.maxChunkSize)
        XCTAssertEqual(chunks[3].count, 500)
    }

    func testChunk_emptyData() {
        let data = Data()
        let chunks = NetworkPackets.chunk(data)

        XCTAssertEqual(chunks.count, 0)
    }

    func testChunk_preservesData() {
        // Ensure chunking doesn't corrupt data
        var original = Data()
        for i: UInt8 in 0..<200 {
            original.append(i)
        }

        let chunks = NetworkPackets.chunk(original)
        let reassembled = chunks.reduce(Data()) { $0 + $1 }

        XCTAssertEqual(reassembled, original)
    }

    // MARK: - Round-trip Conversion

    func testPCMToFloatToPCM_roundTrip() {
        // Create known PCM data
        var original = Data()
        let testValues: [Int16] = [0, 1000, -1000, 16384, -16384, 32767, -32767]
        for value in testValues {
            var v = value
            original.append(Data(bytes: &v, count: 2))
        }

        // Convert to float and back
        let floats = AudioConversion.pcmToFloat(original)
        let result = floats.withUnsafeBufferPointer { ptr in
            AudioConversion.floatToPCM(ptr.baseAddress!, count: floats.count)
        }

        // Compare sample by sample (may have small rounding errors)
        for i in 0..<testValues.count {
            let originalValue = testValues[i]
            let resultValue = result.withUnsafeBytes { ptr -> Int16 in
                ptr.load(fromByteOffset: i * 2, as: Int16.self)
            }
            // Allow for rounding error of 1 LSB
            XCTAssertEqual(originalValue, resultValue, accuracy: 1,
                          "Sample \(i): expected \(originalValue), got \(resultValue)")
        }
    }
}

// Helper for comparing Int16 with accuracy
extension XCTestCase {
    func XCTAssertEqual(_ a: Int16, _ b: Int16, accuracy: Int16, _ message: String = "") {
        XCTAssertTrue(abs(Int(a) - Int(b)) <= Int(accuracy), message)
    }
}
