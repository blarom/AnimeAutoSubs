import SwiftUI
import ScreenCaptureKit
import Combine

struct WindowPickerView: View {
    @ObservedObject var windowEnumerator: BrowserWindowEnumerator
    @ObservedObject var subtitleManager: SubtitleManager
    @ObservedObject var broadcastManager: BroadcastDelayManager
    let onStartBroadcast: (SCWindow) -> Void

    @State private var hasAppeared = false

    private let whisper = WhisperTranscriber()
    private let mecab = MeCabParser()
    /// `OperationQueue` instead of `DispatchQueue` so we can adjust the
    /// concurrent-invocation limit at runtime — the user's "Transcription
    /// load" picker writes into `broadcastManager.transcriptionLoad`,
    /// and we mirror that change to `queue.maxConcurrentOperationCount`
    /// via `.onChange`. Each whisper call is self-contained (unique temp
    /// file, no shared mutable state), so concurrent invocations are safe.
    /// CPU oversaturation (which causes audio dropouts) is purely about
    /// the concurrency count — capped at whatever the user selected.
    private let transcriptionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.animeautosubs.transcription"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = BroadcastDelayManager.TranscriptionLoad.balanced.concurrency
        return q
    }()
    /// Tracks how many whisper subprocesses are currently in flight.
    /// Logged per segment so we can correlate "this subtitle was late" with
    /// "the system was running N concurrent transcriptions at the time".
    private let inflightTracker = InflightTracker()
    /// Tiered hallucination filter. Tiers A/B run synchronously on the
    /// transcription queue; Tier C consults the on-device language model
    /// and runs in a detached `Task` after whisper releases its slot.
    private let hallucinationFilter = HallucinationFilter()

    /// Drop VAD-emitted segments shorter than this — too short to carry
    /// real dialogue and too prone to whisper hallucinations on noise.
    /// Tunable; logged when triggered so we can audit edge cases.
    private static let minSegmentDurationSeconds: Double = 0.30
    /// Window size for the silence-fraction sweep. 100 ms = 1600 samples
    /// at the whisper sample rate; small enough to catch brief pauses
    /// without smoothing them away.
    private static let silenceWindowSeconds: Double = 0.10
    /// Per-window RMS below this counts as silence. Matches the speech
    /// threshold used by `SpeechSegmenter`.
    private static let silenceWindowThreshold: Float = 0.008
    /// Drop the segment if more than this fraction of its 100 ms windows
    /// are below the silence threshold — VAD sometimes emits a stretch
    /// where one brief utterance is wrapped in a much longer quiet tail.
    private static let mostlySilentFractionThreshold: Double = 0.70

    var body: some View {
        VStack(spacing: 14) {
            Text("AnimeAutoSubs")
                .font(.title2.bold())

            Text("Pick a browser window to broadcast")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                Text("After picking a window and confirming the video region, AnimeAutoSubs will broadcast it with a 6-second delay and live Japanese subtitles. Make sure the AnimeAutoSubs Safari extension is enabled — it's how the app controls play / pause on the source video.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))

            if windowEnumerator.availableWindows.isEmpty {
                Text("No browser windows found")
                    .foregroundColor(.secondary)
                    .frame(minHeight: 200)
            } else {
                List(windowEnumerator.availableWindows, id: \.windowID) { window in
                    Button {
                        onStartBroadcast(window)
                    } label: {
                        HStack {
                            Text(window.owningApplication?.applicationName ?? "Unknown")
                                .fontWeight(.medium)
                            Text("— \(window.title ?? "Untitled")")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 200)
            }

            Button("Refresh") {
                Task { await windowEnumerator.refreshWindows() }
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 360)
        .task {
            if !hasAppeared {
                hasAppeared = true
                await windowEnumerator.refreshWindows()
                wireBroadcastTranscription()
                applyTranscriptionLoad()
                // Kick off whisper-server + model load in the background
                // while the user navigates the picker / wizard. Without
                // this, the first user-facing transcription pays ~9 s
                // of cold-start latency. We piggy-back on the existing
                // transcription queue (same pattern as a normal
                // `transcribe` call) so isolation stays consistent.
                transcriptionQueue.addOperation { [whisper] in
                    whisper.warmUp()
                }
            }
        }
        .onChange(of: broadcastManager.transcriptionLoad) { _, _ in
            applyTranscriptionLoad()
        }
    }

    private func applyTranscriptionLoad() {
        let limit = broadcastManager.transcriptionLoad.concurrency
        transcriptionQueue.maxConcurrentOperationCount = limit
        print("[whisper] transcription load → \(broadcastManager.transcriptionLoad.rawValue) (concurrency=\(limit), threads/proc=\(broadcastManager.transcriptionLoad.threadsPerProcess))")
    }

    private func wireBroadcastTranscription() {
        broadcastManager.onSpeechSegmentReady = { [self] samples, segmentStartCMTime in
            // Drop segments whose audio was captured before the most
            // recent seek — they belong to the pre-seek playhead and
            // would otherwise surface as stale subtitles a few seconds
            // after the rebuffer (either because the VAD was still
            // sitting on pre-seek audio when the seek fired, or because
            // a whisper job started before the seek finished after it).
            // The same check runs again after whisper returns; this
            // early bail also avoids wasting CPU on doomed transcriptions.
            if segmentStartCMTime < broadcastManager.lastSeekAt {
                print(String(format: "[seg %.3f] dropped pre-seek (lastSeek=%.3f)",
                             segmentStartCMTime, broadcastManager.lastSeekAt))
                return
            }
            let audioDurationSeconds = Double(samples.count) / BroadcastConstants.whisperSampleRate

            // Stage 1a: drop very short windows. Anything under 300 ms
            // is too short to carry a real line and is the highest-yield
            // hallucination trigger for whisper. Threshold lives in
            // `Self.minSegmentDurationSeconds` — bump it down if real
            // utterances start getting filtered.
            if audioDurationSeconds < Self.minSegmentDurationSeconds {
                print(String(format: "[seg %.3f] skipped pre-whisper — too short (dur=%.3fs, min=%.2fs)",
                             segmentStartCMTime, audioDurationSeconds,
                             Self.minSegmentDurationSeconds))
                return
            }
            // Stage 1b: drop "mostly silent" windows. Whisper happily
            // hallucinates over a 5 s clip with one brief sound and
            // the rest noise. We sweep 100 ms RMS windows and reject
            // when >70 % are below the speech threshold.
            let silenceFrac = Self.silenceFraction(samples)
            if silenceFrac > Self.mostlySilentFractionThreshold {
                print(String(format: "[seg %.3f] skipped pre-whisper — mostly silent (silenceFrac=%.2f > %.2f, dur=%.3fs)",
                             segmentStartCMTime, silenceFrac,
                             Self.mostlySilentFractionThreshold, audioDurationSeconds))
                return
            }

            // Time the segment was emitted by the VAD (now). Used as the
            // baseline for queue wait + total latency calculations below.
            let emittedAt = Date()
            // OperationQueue caps concurrency to `transcriptionLoad.concurrency`
            // — overflow operations queue here. The wait that adds is
            // strictly preferable to the audio-thread starvation that
            // unbounded parallelism would cause.
            transcriptionQueue.addOperation {
                let inflightAtStart = inflightTracker.increment()
                defer { _ = inflightTracker.decrement() }

                let whisperStartedAt = Date()
                let queueWait = whisperStartedAt.timeIntervalSince(emittedAt)
                let threads = broadcastManager.transcriptionLoad.threadsPerProcess

                guard let whisperSegments = whisper.transcribe(audioSamples: samples, threads: threads) else {
                    print(String(format: "[seg %.3f] transcribe returned nil (silent or model missing) inflight=%d",
                                 segmentStartCMTime, inflightAtStart))
                    return
                }

                // Re-check after whisper: a seek may have happened while
                // this job was running. Same rule as the pre-queue check
                // above — discard so the user doesn't see lines from the
                // pre-seek timeline pop in once the rebuffer settles.
                if segmentStartCMTime < broadcastManager.lastSeekAt {
                    print(String(format: "[seg %.3f] dropped post-whisper (seek during transcription)",
                                 segmentStartCMTime))
                    return
                }

                let whisperFinishedAt = Date()
                let whisperDuration = whisperFinishedAt.timeIntervalSince(whisperStartedAt)

                // 1-minute load average. Below the M-series core count
                // (e.g. 8 on M1 / 10 on M1 Pro) means the system has spare
                // capacity; above it means whisper is competing for cores.
                var loads = [Double](repeating: 0, count: 1)
                getloadavg(&loads, 1)

                // Tier C may `await` the on-device LLM, which can take
                // hundreds of milliseconds. Hand off to a Task so this
                // operation's whisper concurrency slot is released
                // before the LLM round-trip starts. Subtitle ordering is
                // independent (each carries its own `displayAt`).
                //
                // Run the post-processing on the main actor so the
                // synchronous string ops play nicely with the project's
                // default-MainActor isolation. The internal `await` on
                // the LLM call releases the main actor for the duration
                // of inference.
                Task { @MainActor [self] in
                    for sub in whisperSegments {
                        // Padding-zone hallucination filter. whisper-cpp pads
                        // short inputs to 30 s with zeros internally, and the
                        // model often hallucinates a sign-off transcription
                        // somewhere in that padded silence. Any segment whose
                        // `startSeconds` is past the actual audio we sent is,
                        // by definition, transcribing whisper's own padding.
                        // Drop it. Free, exact, zero false-positive risk.
                        if sub.startSeconds >= audioDurationSeconds {
                            print(String(format: "[seg %.3f] dropped (padding-zone hallucination, start=%.2fs > audio=%.2fs): \"%@\"",
                                         segmentStartCMTime, sub.startSeconds, audioDurationSeconds, sub.text))
                            continue
                        }

                        let normalized = hallucinationFilter.normalize(sub.text)
                        if normalized.isEmpty {
                            print(String(format: "[seg %.3f] dropped by normalize: \"%@\"",
                                         segmentStartCMTime, sub.text))
                            continue
                        }

                        // Tier A + Tier B sync — patterns that are never
                        // real dialogue, plus stock "thanks for watching"
                        // hallucinations.
                        if case .drop(let reason) = hallucinationFilter.quickCheck(text: normalized) {
                            print(String(format: "[seg %.3f] dropped by %@: \"%@\"",
                                         segmentStartCMTime, reason, normalized))
                            continue
                        }

                        // Tier C async — soft-marker phrases get an LLM
                        // judgment in context. Real dialogue containing
                        // "thank you" / "ありがとう" passes; hallucinated
                        // overflow is rejected.
                        if hallucinationFilter.isAmbiguous(text: normalized) {
                            let plausible = await hallucinationFilter.plausibleInContext(text: normalized)
                            if !plausible {
                                print(String(format: "[seg %.3f] dropped by tier-C LLM: \"%@\"",
                                             segmentStartCMTime, normalized))
                                continue
                            }
                            print(String(format: "[seg %.3f] tier-C LLM kept: \"%@\"",
                                         segmentStartCMTime, normalized))
                        }

                        let absoluteMediaTime = segmentStartCMTime + sub.startSeconds
                        let trueHeadroom = (absoluteMediaTime + broadcastManager.delaySeconds) - CACurrentMediaTime()
                        let scheduledDisplay = computeDisplayDate(forSegmentMediaTime: absoluteMediaTime)
                        let totalLatency = Date().timeIntervalSince(emittedAt)

                        // Per-segment timing breakdown — useful for correlating
                        // late subtitles with CPU pressure. Fields:
                        //   wait   = time the segment sat in the queue before
                        //            whisper started
                        //   whisp  = whisper subprocess wallclock time
                        //   total  = end-to-end latency from VAD emit to scheduling
                        //   inflt  = concurrent whisper invocations at this seg's start
                        //   load1m = system 1-min load average
                        //   late   = how far past the display deadline we are
                        //            (negative if on time, positive if late)
                        let lateMarker = trueHeadroom < 0 ? String(format: " LATE=%.2fs", -trueHeadroom) : ""
                        print(String(format: "[seg %.3f] wait=%.2fs whisp=%.2fs total=%.2fs inflt=%d load1m=%.1f%@ → \"%@\"",
                                     segmentStartCMTime, queueWait, whisperDuration, totalLatency,
                                     inflightAtStart, loads[0], lateMarker, normalized))

                        let tokens = mecab.tokenize(normalized) ?? [FuriganaPair(surface: normalized, reading: nil)]
                        subtitleManager.schedule(tokens: tokens, displayAt: scheduledDisplay)
                        hallucinationFilter.recordDisplayed(normalized)
                    }
                }
            }
        }
    }

    /// Wall-clock Date when a segment's first sample (at media time `cmtime`)
    /// will be heard through the delayed-playback engine.
    private func computeDisplayDate(forSegmentMediaTime cmtime: CFTimeInterval) -> Date {
        let nowMt = CACurrentMediaTime()
        let secondsUntilDisplay = (cmtime + broadcastManager.delaySeconds) - nowMt
        return Date(timeIntervalSinceNow: max(0, secondsUntilDisplay))
    }

    /// Fraction of `windowSeconds`-sized chunks of `samples` whose RMS
    /// is below the speech threshold. 1.0 means everything's silent;
    /// 0.0 means everything's above threshold. Used to reject VAD
    /// segments where one brief sound is wrapped in a much longer
    /// quiet tail — whisper hallucinates over those reliably.
    private static func silenceFraction(_ samples: [Float],
                                        sampleRate: Double = BroadcastConstants.whisperSampleRate,
                                        windowSeconds: Double = silenceWindowSeconds,
                                        threshold: Float = silenceWindowThreshold) -> Double {
        let windowSize = max(1, Int(windowSeconds * sampleRate))
        guard samples.count >= windowSize else { return 1.0 }
        var totalWindows = 0
        var silentWindows = 0
        var i = 0
        while i + windowSize <= samples.count {
            var sumOfSquares: Float = 0
            for j in i..<(i + windowSize) {
                let s = samples[j]
                sumOfSquares += s * s
            }
            let rms = (sumOfSquares / Float(windowSize)).squareRoot()
            totalWindows += 1
            if rms < threshold { silentWindows += 1 }
            i += windowSize
        }
        return totalWindows == 0 ? 1.0 : Double(silentWindows) / Double(totalWindows)
    }
}

/// Thread-safe counter for concurrent whisper invocations. Used purely
/// for diagnostic logging — we want to see the inflight count at the
/// moment each segment started transcribing so we can correlate
/// CPU pressure with subtitle delays.
private final class InflightTracker {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    @discardableResult
    func decrement() -> Int {
        lock.lock(); defer { lock.unlock() }
        count -= 1
        return count
    }
}
