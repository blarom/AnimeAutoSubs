import Foundation

/// One subtitle segment within a transcribed chunk: the recognized text plus
/// when (in seconds, relative to the chunk's first sample) the segment begins.
/// whisper-server emits these as `segments[].start` / `segments[].text` in
/// the `verbose_json` response body.
struct WhisperSegment {
    let startSeconds: Double
    let text: String
}

/// Sends audio chunks to a long-lived `whisper-server` over HTTP. Replaces
/// the per-chunk `whisper-cli` subprocess model: the model is loaded once
/// at server start, requests pay only the (tiny) HTTP overhead.
///
/// Multiple `WhisperTranscriber` instances share `WhisperServer.shared`.
class WhisperTranscriber {
    private let server: WhisperServer
    private let urlSession: URLSession
    private var loggedStartupError = false

    init(server: WhisperServer = .shared) {
        self.server = server
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 4
        self.urlSession = URLSession(configuration: cfg)
    }

    /// Transcribe one VAD-delimited chunk. Each returned segment carries
    /// its start offset (seconds from the chunk's first sample) so callers
    /// can schedule the subtitle for the moment that segment's audio
    /// actually plays.
    ///
    /// The `threads` argument is accepted for API compatibility with the
    /// previous subprocess implementation but is honored at server-startup
    /// time, not per-request. Whisper-server applies a single thread count
    /// across its lifetime.
    func transcribe(audioSamples: [Float],
                    sampleRate: Int = Int(BroadcastConstants.whisperSampleRate),
                    threads: Int = 4) -> [WhisperSegment]? {
        guard !isSilent(audioSamples) else { return nil }

        do {
            try server.ensureStarted()
        } catch {
            if !loggedStartupError {
                loggedStartupError = true
                print("[whisper] startup failed: \(error)")
            }
            return nil
        }

        let wavData = buildWAV(samples: audioSamples, sampleRate: sampleRate)

        let inDur = Double(audioSamples.count) / Double(sampleRate)
        let started = Date()

        guard let json = postInference(wavData: wavData) else { return nil }
        let segments = parseSegments(from: json)

        let elapsed = Date().timeIntervalSince(started)
        let preview = segments.map(\.text).joined(separator: " | ")
        print(String(format: "[whisper] in=%.2fs took=%.2fs out=%d → \"%@\"",
                     inDur, elapsed, segments.count, preview))
        return segments.isEmpty ? nil : segments
    }

    /// Force whisper-server to load the model now, before the first
    /// real segment arrives. Without this, the first user-facing
    /// transcription pays ~9 seconds of model-load latency (visible
    /// as 5+ second LATE markers on the first batch of subtitles).
    /// Idempotent and safe to call repeatedly — once the model is
    /// loaded, subsequent inferences pay only the per-request cost.
    /// Blocks the calling thread; spawn from a background `Task`.
    func warmUp() {
        do {
            try server.ensureStarted()
        } catch {
            if !loggedStartupError {
                loggedStartupError = true
                print("[whisper] warmup ensureStarted failed: \(error)")
            }
            return
        }
        // 200 ms of low-amplitude 100 Hz tone. Above the silence gate
        // so the request reaches whisper-cpp; quiet enough that the
        // model returns no segments. We discard the result — only the
        // model-load side effect matters.
        let sr = Int(BroadcastConstants.whisperSampleRate)
        let n = sr / 5
        let samples: [Float] = (0..<n).map { i in
            sin(Float(i) * 2 * .pi * 100 / Float(sr)) * 0.05
        }
        let wav = buildWAV(samples: samples, sampleRate: sr)
        let started = Date()
        _ = postInference(wavData: wav)
        print(String(format: "[whisper] warmup completed in %.2fs (model now resident)",
                     Date().timeIntervalSince(started)))
    }

    // MARK: - HTTP

    private func postInference(wavData: Data) -> [String: Any]? {
        let boundary = "AnimeAutoSubsBoundary-\(UUID().uuidString)"
        var body = Data()

        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        func appendField(_ name: String, value: String) {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            appendString("\(value)\r\n")
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n")
        appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        appendString("\r\n")

        appendField("response_format", value: "verbose_json")
        appendField("language", value: "ja")
        appendField("temperature", value: "0.0")

        appendString("--\(boundary)--\r\n")

        var request = URLRequest(url: server.inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var responseStatus: Int = 0
        let task = urlSession.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse {
                responseStatus = http.statusCode
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let err = responseError {
            print("[whisper] HTTP error: \(err.localizedDescription)")
            return nil
        }
        if responseStatus >= 400 {
            let preview = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            print("[whisper] HTTP \(responseStatus): \(preview.prefix(200))")
            return nil
        }
        guard let data = responseData,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any] else {
            print("[whisper] failed to parse JSON response")
            return nil
        }
        return json
    }

    private func parseSegments(from json: [String: Any]) -> [WhisperSegment] {
        guard let raw = json["segments"] as? [[String: Any]] else { return [] }
        var out: [WhisperSegment] = []
        for seg in raw {
            let start = (seg["start"] as? Double) ?? 0
            let text = (seg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }
            out.append(WhisperSegment(startSeconds: start, text: text))
        }
        return out
    }

    // MARK: - Utilities

    private func isSilent(_ samples: [Float], threshold: Float = 0.008) -> Bool {
        guard !samples.isEmpty else { return true }
        return AudioMath.rms(samples) < threshold
    }

    /// Build a 16-bit PCM mono WAV in memory. We don't go through disk —
    /// the server accepts the bytes directly as the multipart `file` field.
    private func buildWAV(samples: [Float], sampleRate: Int) -> Data {
        let numSamples = samples.count
        let bitsPerSample: Int = 16
        let numChannels: Int = 1
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = numSamples * blockAlign
        let fileSize = 36 + dataSize

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        appendString("RIFF")
        appendUInt32(UInt32(fileSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(UInt16(numChannels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            withUnsafeBytes(of: intSample.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }
}
