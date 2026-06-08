import Foundation
import AVFoundation

/// Tiny audio-math utilities shared by the silence detector, the speech
/// segmenter, and the broadcast manager's source-state probe.
enum AudioMath {
    /// Root-mean-square amplitude of a `Float` PCM sample array. Returns 0
    /// for an empty buffer rather than NaN.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// RMS over the first channel of a `AVAudioPCMBuffer` without the cost
    /// of materializing a `[Float]`. Used in the audio-active probe path,
    /// which runs on every captured buffer.
    static func rms(of pcm: AVAudioPCMBuffer) -> Float {
        guard let channelData = pcm.floatChannelData else { return 0 }
        let frames = Int(pcm.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        return (sum / Float(frames)).squareRoot()
    }
}
