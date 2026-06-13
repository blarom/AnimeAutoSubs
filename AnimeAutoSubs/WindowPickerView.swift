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
                Text("After picking a window and confirming the video region, AnimeAutoSubs will broadcast it with a 5-second delay and live Japanese subtitles. Make sure the AnimeAutoSubs Safari extension is enabled — it's how the app controls play / pause on the source video.")
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
                let audioDurationSeconds = Double(samples.count) / BroadcastConstants.whisperSampleRate

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

                    let cleaned = cleanTranscription(sub.text)
                    if cleaned.isEmpty {
                        print(String(format: "[seg %.3f] dropped by cleanTranscription: \"%@\"",
                                     segmentStartCMTime, sub.text))
                        continue
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
                                 inflightAtStart, loads[0], lateMarker, cleaned))

                    let tokens = mecab.tokenize(cleaned) ?? [FuriganaPair(surface: cleaned, reading: nil)]
                    subtitleManager.schedule(tokens: tokens, displayAt: scheduledDisplay)
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

    private func cleanTranscription(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let bracketPattern = #"[\[【((][^\]】)）]*[\]】)）]"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let hallucinations: Set<String> = [
            "音声", "音楽", "拍手", "笑",
            "ご視聴ありがとうございました",
            "ご清聴ありがとうございました",
            "ありがとうございました",
            "字幕視聴ありがとうございました",
            "みんな見てくれてありがとう",
            "みんな見てくれてありがとう!",
            "みんな見てくれてありがとう!",
            "-end-",
            "(end)", "(END)",
            "Thanks for watching!",
            "you", "Thank you.", "Thank you",
        ]
        if hallucinations.contains(cleaned) { return "" }

        // Regex-based hallucination patterns. These catch entire classes
        // of stock whisper outputs without needing every variant in the
        // set above. All patterns are deliberately strict (anchored to
        // full-string match) so genuine dialogue can't slip through.
        //
        // Subtitler-credit patterns:
        //   "サブタイトル:ひかり" / "サブタイトル：たけし" / "字幕：ABC" / "字幕:foo"
        // No character ever speaks these — they're whisper learning that
        // anime captions end with subtitler credits.
        let hallucinationPatterns: [String] = [
            #"^\s*サブタイトル\s*[:：].*$"#,
            #"^\s*字幕\s*[:：].*$"#,
            #"^\s*翻訳\s*[:：].*$"#,
            #"^\s*Subtitle\s*[:：].*$"#,
            #"^\s*Translation\s*[:：].*$"#,
        ]
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
                return ""
            }
        }

        if cleaned.allSatisfy({ $0.isWhitespace || $0 == "." || $0 == "…" || $0 == "、" || $0 == "。" }) {
            return ""
        }

        if cleaned.count <= 1 { return "" }
        return cleaned
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
