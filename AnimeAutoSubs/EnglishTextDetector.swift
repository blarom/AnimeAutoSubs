import Foundation
import Vision
import CoreGraphics

/// Detects English-language text rectangles in video frames.
///
/// Designed to identify burned-in English subtitles so they can be visually blurred
/// without obscuring Japanese text. Runs at most one Vision request at a time on its
/// own utility-priority queue. Results are reported in normalized Vision coordinates
/// (origin bottom-left).
///
/// Each `submit` call carries the frame's `captureTime`, which is passed straight
/// through to `onRectsUpdated`. Callers use it to associate the detection result
/// with the originating frame so the blur can be applied at exactly the moment
/// that frame is displayed.
final class EnglishTextDetector {
    /// Emitted on the main queue: `(rects, activationCaptureTime)`. The activation
    /// time is the captureTime of the frame the detection ran on.
    var onRectsUpdated: (([CGRect], CFTimeInterval) -> Void)?

    private enum Tuning {
        static let minTextHeight: Float = 0.018
        static let minConfidence: Float = 0.5
        static let minDetectionHeight: CGFloat = 0.02
        static let latinRatioThreshold: Double = 0.7
        static let cornerZoneHorizontalEdge: CGFloat = 0.15
        static let cornerZoneVerticalEdge: CGFloat = 0.25
        /// Max horizontal gap (normalized) for merging two rects on the same line.
        static let mergeHorizontalGap: CGFloat = 0.05
    }

    private let queue = DispatchQueue(label: "broadcast.vision", qos: .utility)
    private var inFlight = false

    /// Submit a frame for detection. Drops the request if a previous one is still running.
    /// The `captureTime` is passed through to `onRectsUpdated` unchanged.
    func submit(_ cgImage: CGImage, captureTime: CFTimeInterval) {
        if inFlight { return }
        inFlight = true
        queue.async { [weak self] in
            self?.runDetection(on: cgImage, captureTime: captureTime)
        }
    }

    private func runDetection(on cgImage: CGImage, captureTime: CFTimeInterval) {
        defer {
            DispatchQueue.main.async { [weak self] in self?.inFlight = false }
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        // .accurate provides reliable topCandidates so isMostlyLatin can filter
        // Japanese vs Latin text. .fast was tried but produces weaker text content
        // for our use case, which caused the isMostlyLatin filter to reject most
        // detections and the blur to silently stop appearing.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = Tuning.minTextHeight

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results else { return }
        let rects = observations.compactMap { obs -> CGRect? in
            guard obs.confidence > Tuning.minConfidence else { return nil }
            let topText = obs.topCandidates(1).first?.string ?? ""
            guard isMostlyLatin(topText) else { return nil }
            guard obs.boundingBox.height >= Tuning.minDetectionHeight else { return nil }
            // Skip likely corner watermarks.
            if isInCornerZone(obs.boundingBox) { return nil }
            return obs.boundingBox
        }

        let merged = mergeRects(rects)

        DispatchQueue.main.async { [weak self] in
            self?.onRectsUpdated?(merged, captureTime)
        }
    }

    /// True if the rect's center sits in one of the four corner zones.
    /// Used to skip static logos/watermarks while keeping bottom/top-center subtitles.
    private func isInCornerZone(_ rect: CGRect) -> Bool {
        let inHorizontalEdge = rect.midX < Tuning.cornerZoneHorizontalEdge
            || rect.midX > 1 - Tuning.cornerZoneHorizontalEdge
        let inVerticalEdge = rect.midY < Tuning.cornerZoneVerticalEdge
            || rect.midY > 1 - Tuning.cornerZoneVerticalEdge
        return inHorizontalEdge && inVerticalEdge
    }

    private func isMostlyLatin(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var latin = 0
        var total = 0
        for scalar in s.unicodeScalars where !scalar.properties.isWhitespace {
            total += 1
            // Basic Latin + Latin-1 Supplement + Latin Extended-A/B
            if (0x0020...0x024F).contains(scalar.value) {
                latin += 1
            }
        }
        guard total > 0 else { return false }
        return Double(latin) / Double(total) >= Tuning.latinRatioThreshold
    }

    private func mergeRects(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        let sorted = rects.sorted { ($0.midY, $0.midX) < ($1.midY, $1.midX) }
        var result: [CGRect] = []
        for r in sorted {
            if let last = result.last,
               abs(last.midY - r.midY) < (r.height + last.height) * 0.5,
               r.minX - last.maxX < Tuning.mergeHorizontalGap {
                result[result.count - 1] = last.union(r)
            } else {
                result.append(r)
            }
        }
        return result
    }
}
