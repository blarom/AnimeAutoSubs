import Foundation

/// One subtitle segment within a transcribed chunk: the recognized text plus
/// when (in seconds, relative to the chunk's first sample) the segment begins.
/// whisper-cli emits these as one timestamped line per segment.
struct WhisperSegment {
    let startSeconds: Double
    let text: String
}

class WhisperTranscriber {
    private let modelPath: String
    private let whisperPath: String
    private let tempDir: String

    init() {
        // Application Support is sandbox-/TCC-friendly: no permission prompt
        // when reading from it (unlike ~/Downloads).
        let appSupportDir = NSHomeDirectory() + "/Library/Application Support/AnimeAutoSubs"
        self.modelPath = appSupportDir + "/ggml-small.bin"
        self.whisperPath = "/opt/homebrew/bin/whisper-cli"
        self.tempDir = NSTemporaryDirectory() + "AnimeAutoSubs"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    /// Transcribe an audio chunk into one or more segments. Each segment carries
    /// the start offset (seconds from the chunk's first sample) so callers can
    /// schedule the subtitle for the moment that segment's audio actually plays
    /// — instead of using the chunk's start time for everything, which makes
    /// every subtitle in a multi-sentence chunk appear too early.
    func transcribe(audioSamples: [Float],
                    sampleRate: Int = Int(BroadcastConstants.whisperSampleRate),
                    threads: Int = 4) -> [WhisperSegment]? {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            logModelMissingOnce()
            return nil
        }
        guard !isSilent(audioSamples) else { return nil }

        let wavPath = tempDir + "/chunk_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        defer { try? FileManager.default.removeItem(atPath: wavPath) }

        guard writeWAV(samples: audioSamples, sampleRate: sampleRate, to: wavPath) else {
            return nil
        }

        let inDur = Double(audioSamples.count) / Double(sampleRate)
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        // No --no-timestamps: we want per-segment "[hh:mm:ss.mmm --> ...]" output.
        process.arguments = [
            "-m", modelPath,
            "-l", "ja",
            "-f", wavPath,
            "-t", "\(threads)",
            "--no-prints",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[whisper] process failed: \(error)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let segments = parseSegments(output)
        let elapsed = Date().timeIntervalSince(started)
        let preview = segments.map(\.text).joined(separator: " | ")
        print(String(format: "[whisper] in=%.2fs took=%.2fs out=%d → \"%@\"", inDur, elapsed, segments.count, preview))
        return segments.isEmpty ? nil : segments
    }

    /// Parse whisper-cli's stdout. Each transcribed segment is one line of:
    ///   `[HH:MM:SS.mmm --> HH:MM:SS.mmm]   text...`
    /// We capture the start time and the text body.
    private static let segmentLinePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\[(\d+):(\d+):(\d+)\.(\d+)\s*-->.*?\]\s*(.+)"#)
    }()

    private func parseSegments(_ output: String) -> [WhisperSegment] {
        guard let regex = Self.segmentLinePattern else { return [] }
        var segments: [WhisperSegment] = []
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let nsRange = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange) else { continue }

            func numberAt(_ groupIndex: Int) -> Double {
                guard let range = Range(match.range(at: groupIndex), in: line) else { return 0 }
                return Double(line[range]) ?? 0
            }
            let h = numberAt(1), m = numberAt(2), s = numberAt(3), ms = numberAt(4)
            let startSeconds = h * 3600 + m * 60 + s + ms / 1000

            guard let textRange = Range(match.range(at: 5), in: line) else { continue }
            let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            segments.append(WhisperSegment(startSeconds: startSeconds, text: text))
        }
        return segments
    }

    private var loggedModelMissing = false
    private func logModelMissingOnce() {
        if loggedModelMissing { return }
        loggedModelMissing = true
        print("[whisper] model not found at \(modelPath). Place ggml-small.bin in ~/Library/Application Support/AnimeAutoSubs/ to enable transcription.")
    }

    private func isSilent(_ samples: [Float], threshold: Float = 0.008) -> Bool {
        guard !samples.isEmpty else { return true }
        return AudioMath.rms(samples) < threshold
    }

    private func writeWAV(samples: [Float], sampleRate: Int, to path: String) -> Bool {
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

        return FileManager.default.createFile(atPath: path, contents: data)
    }
}
