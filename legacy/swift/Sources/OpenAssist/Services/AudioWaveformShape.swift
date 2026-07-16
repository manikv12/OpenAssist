import AVFoundation
import Foundation

enum AudioWaveformShape {
    static let defaultBinCount = 7
    private static let amplitudeNoiseFloor: Float = 0.012
    private static let visualHeadroom: Float = 0.90

    static func bins(from buffer: AVAudioPCMBuffer, count: Int = defaultBinCount) -> [Float] {
        guard let channelData = buffer.floatChannelData?.pointee else {
            return Array(repeating: 0, count: count)
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return Array(repeating: 0, count: count)
        }

        let samples = UnsafeBufferPointer(start: channelData, count: frameCount)
        return bins(from: samples, count: count)
    }

    static func bins(from samples: UnsafeBufferPointer<Float>, count: Int = defaultBinCount) -> [Float] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else {
            return Array(repeating: 0, count: count)
        }

        let framesPerBin = max(1, Int(ceil(Double(samples.count) / Double(count))))
        var values: [Float] = []
        values.reserveCapacity(count)

        for binIndex in 0..<count {
            let start = min(samples.count, binIndex * framesPerBin)
            let end = min(samples.count, start + framesPerBin)
            guard start < end else {
                values.append(0)
                continue
            }

            var sumSquares: Float = 0
            var peak: Float = 0
            for sampleIndex in start..<end {
                let amplitude = abs(samples[sampleIndex])
                sumSquares += amplitude * amplitude
                peak = max(peak, amplitude)
            }

            let frameCount = Float(end - start)
            let rms = sqrtf(max(sumSquares / max(frameCount, 1), 0))
            let mixed = (rms * 0.48) + (peak * 0.52)
            values.append(normalizedBinLevel(from: mixed))
        }

        if values.count < count {
            values.append(contentsOf: repeatElement(0, count: count - values.count))
        }

        return values
    }

    static func normalizedBinLevel(from amplitude: Float) -> Float {
        let clamped = max(0, min(1, amplitude))
        guard clamped > amplitudeNoiseFloor else { return 0 }

        let normalized = (clamped - amplitudeNoiseFloor) / (1 - amplitudeNoiseFloor)
        let shaped = powf(normalized, 0.48)
        return max(0, min(visualHeadroom, shaped * visualHeadroom))
    }
}
