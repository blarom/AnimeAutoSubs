import Foundation
import AVFoundation

/// Voice-Activity-Detection (VAD) based audio segmenter. Emits variable-
/// length audio segments aligned to acoustic utterance boundaries, so
/// whisper transcribes one sentence at a time and the resulting subtitle
/// is anchored to the wall-clock instant that sentence began.
///
/// How it works:
/// - Incoming PCM is downsampled to 16 kHz mono and split into 20 ms windows.
/// - Energy (RMS) per window classifies it as speech or silence.
/// - A simple two-state machine tracks "in-speech" with hysteresis: the
///   segment ends after `silenceWindowsToEnd` consecutive silent windows
///   trail off the speech.
/// - On segment end, the accumulated samples + the wall-clock time at which
///   speech began are reported via `onSegmentReady`. That start time anchors
///   the eventual subtitle to the moment its sentence's first sample plays
///   through the delay buffer (segmentStartTime + delaySeconds).
///
/// `maxSegmentSamples` force-emits long monologues so transcription latency
/// always fits inside the 5-second playback delay budget.
final class SpeechSegmenter {
    /// Emitted when a segment finishes (silence-end or force-split).
    /// `startTime` is `CACurrentMediaTime()` at the first sample of the
    /// detected speech run.
    var onSegmentReady: ((_ samples: [Float], _ startTime: CFTimeInterval) -> Void)?

    private enum Tuning {
        /// 20 ms windows at 16 kHz.
        static let windowSamples: Int = 320
        static let windowDuration: Double = 0.02

        /// RMS threshold above which a window counts as speech. Slightly above
        /// `WhisperTranscriber.isSilent`'s 0.008 to avoid handing whisper any
        /// audio it would silently drop anyway.
        static let speechRMSThreshold: Float = 0.012

        /// 300 ms of trailing silence ends the current segment.
        static let silenceWindowsToEnd: Int = 15

        /// Keep ~100 ms of trailing silence in the emitted samples so whisper
        /// has acoustic context for the final consonant.
        static let trailingSilenceWindowsToKeep: Int = 5

        /// Hard cap (4 s) so transcription + scheduling fits inside the 5 s
        /// delay buffer for monologues with no pause.
        static let maxSegmentSamples: Int = 64_000
    }

    // Buffered un-windowed input samples.
    private var pendingSamples: [Float] = []
    /// Wall-clock time of the first sample currently in `pendingSamples`.
    /// Advances by `windowDuration` each time a window is consumed.
    private var pendingSamplesStartTime: CFTimeInterval?

    // VAD state.
    private var inSpeech: Bool = false
    private var trailingSilenceWindows: Int = 0
    private var segmentSamples: [Float] = []
    /// Wall-clock time of the first sample of the current segment (start of speech).
    private var segmentStartTime: CFTimeInterval?

    private let lock = NSLock()

    func reset() {
        lock.lock()
        pendingSamples.removeAll()
        pendingSamplesStartTime = nil
        inSpeech = false
        trailingSilenceWindows = 0
        segmentSamples.removeAll()
        segmentStartTime = nil
        lock.unlock()
    }

    /// Append a buffer of PCM (any sample rate / 1-2 channels). Drives the VAD
    /// state machine and emits completed segments via `onSegmentReady`.
    func feed(_ pcm: AVAudioPCMBuffer) {
        guard let channelData = pcm.floatChannelData else { return }
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0 else { return }

        let inputSampleRate = pcm.format.sampleRate
        let targetRate = BroadcastConstants.whisperSampleRate
        let ratio = inputSampleRate / targetRate
        let outputCount = Int(Double(frameCount) / ratio)
        if outputCount <= 0 { return }

        let leftCh = channelData[0]
        let rightCh: UnsafeMutablePointer<Float>? = pcm.format.channelCount > 1 ? channelData[1] : nil

        var downsampled: [Float] = []
        downsampled.reserveCapacity(outputCount)
        for i in 0..<outputCount {
            let srcIdx = Int(Double(i) * ratio)
            if srcIdx >= frameCount { break }
            let l = leftCh[srcIdx]
            let r = rightCh?[srcIdx] ?? l
            downsampled.append((l + r) * 0.5)
        }

        // The just-arrived buffer covers `bufferDuration` seconds and ended
        // approximately at `now`, so its first sample is `bufferDuration` ago.
        let bufferDuration = Double(frameCount) / inputSampleRate
        let firstSampleTime = CACurrentMediaTime() - bufferDuration

        var emissions: [(samples: [Float], startTime: CFTimeInterval)] = []

        lock.lock()
        if pendingSamples.isEmpty {
            pendingSamplesStartTime = firstSampleTime
        }
        pendingSamples.append(contentsOf: downsampled)

        while pendingSamples.count >= Tuning.windowSamples {
            let window = Array(pendingSamples.prefix(Tuning.windowSamples))
            pendingSamples.removeFirst(Tuning.windowSamples)
            let windowStartTime = pendingSamplesStartTime ?? firstSampleTime
            pendingSamplesStartTime = windowStartTime + Tuning.windowDuration

            if let segment = stateMachine(window: window, windowStartTime: windowStartTime) {
                emissions.append(segment)
            }
        }
        lock.unlock()

        for e in emissions {
            onSegmentReady?(e.samples, e.startTime)
        }
    }

    /// Updates VAD state for one window. Returns a completed segment to emit
    /// if speech just ended (or the max-duration cap was reached).
    private func stateMachine(window: [Float], windowStartTime: CFTimeInterval) -> (samples: [Float], startTime: CFTimeInterval)? {
        let isSpeech = AudioMath.rms(window) >= Tuning.speechRMSThreshold

        if !inSpeech {
            if isSpeech {
                // Silence → speech: open a new segment starting at this window's first sample.
                inSpeech = true
                trailingSilenceWindows = 0
                segmentStartTime = windowStartTime
                segmentSamples = window
            }
            // else: continuing silence — ignore.
            return nil
        }

        // Currently in-speech.
        segmentSamples.append(contentsOf: window)
        if isSpeech {
            trailingSilenceWindows = 0
        } else {
            trailingSilenceWindows += 1
            if trailingSilenceWindows >= Tuning.silenceWindowsToEnd {
                return endSegment()
            }
        }
        if segmentSamples.count >= Tuning.maxSegmentSamples {
            return endSegment()
        }
        return nil
    }

    private func endSegment() -> (samples: [Float], startTime: CFTimeInterval)? {
        guard let startTime = segmentStartTime else { return nil }
        // Trim trailing silence beyond the keep-window so the segment is clean.
        let drop = max(0, trailingSilenceWindows - Tuning.trailingSilenceWindowsToKeep) * Tuning.windowSamples
        let outSamples = drop > 0
            ? Array(segmentSamples.prefix(segmentSamples.count - drop))
            : segmentSamples

        let dur = Double(outSamples.count) / BroadcastConstants.whisperSampleRate
        print(String(format: "[seg %.3f] vad emit dur=%.2fs samples=%d", startTime, dur, outSamples.count))

        segmentSamples = []
        segmentStartTime = nil
        inSpeech = false
        trailingSilenceWindows = 0
        return (outSamples, startTime)
    }
}
