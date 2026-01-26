import Foundation
import Accelerate

/// Pure functions for audio format conversion - easily testable
enum AudioConversion {

    /// Convert 16-bit PCM samples to 32-bit float samples
    /// - Parameter pcmData: Raw PCM data (Int16, little-endian)
    /// - Returns: Array of float samples normalized to [-1.0, 1.0]
    static func pcmToFloat(_ pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / 2
        var floatSamples = [Float](repeating: 0, count: sampleCount)

        pcmData.withUnsafeBytes { ptr in
            guard let samples = ptr.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                floatSamples[i] = Float(samples[i]) / 32768.0
            }
        }

        return floatSamples
    }

    /// Convert 32-bit float samples to 16-bit PCM data
    /// - Parameter floatSamples: Float samples in range [-1.0, 1.0]
    /// - Returns: Raw PCM data (Int16, little-endian)
    static func floatToPCM(_ floatSamples: UnsafePointer<Float>, count: Int) -> Data {
        var pcmData = Data(capacity: count * 2)

        for i in 0..<count {
            let sample = max(-1, min(1, floatSamples[i]))
            var intSample = Int16(sample * 32767)
            pcmData.append(Data(bytes: &intSample, count: 2))
        }

        return pcmData
    }

    /// Calculate RMS (root mean square) level of audio samples
    /// - Parameter samples: Float audio samples
    /// - Returns: RMS value (0.0 = silence, higher = louder)
    static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    /// Count non-zero samples and find max amplitude
    /// - Parameter pcmData: Raw PCM data
    /// - Returns: Tuple of (nonZeroCount, maxAmplitude)
    static func analyzeAudio(_ pcmData: Data) -> (nonZeroCount: Int, maxAmplitude: Int16) {
        var nonZero = 0
        var maxAmp: Int16 = 0

        pcmData.withUnsafeBytes { ptr in
            guard let samples = ptr.bindMemory(to: Int16.self).baseAddress else { return }
            let count = pcmData.count / 2
            for i in 0..<count {
                let sample = samples[i]
                if sample != 0 {
                    nonZero += 1
                    if abs(sample) > abs(maxAmp) {
                        maxAmp = sample
                    }
                }
            }
        }

        return (nonZero, maxAmp)
    }
}

/// Pure functions for network packet handling
enum NetworkPackets {

    /// Maximum safe UDP payload size to avoid fragmentation
    static let maxChunkSize = 1400

    /// Split data into chunks suitable for UDP transmission
    /// - Parameter data: Data to chunk
    /// - Returns: Array of data chunks, each <= maxChunkSize
    static func chunk(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var offset = 0

        while offset < data.count {
            let end = min(offset + maxChunkSize, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }

        return chunks
    }
}
