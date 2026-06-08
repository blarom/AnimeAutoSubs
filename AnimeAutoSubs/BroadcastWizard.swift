import Foundation
import ScreenCaptureKit
import AppKit
import Vision
import Combine

/// Drives the user-facing setup flow: pick a window → adjust the video region →
/// broadcasting. Source play/pause is delegated to the Safari Web Extension
/// via `ExtensionBridge`, so there's no calibration step — the wizard's only
/// job is teaching the broadcast where the video lives inside the source
/// window.
@MainActor
final class BroadcastWizard: ObservableObject {
    enum Stage: Equatable {
        case idle
        case fine
        case broadcasting

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .fine: return "Fine"
            case .broadcasting: return "Broadcasting"
            }
        }
    }

    @Published var stage: Stage = .idle
    @Published var fineRect: CGRect = .zero
    @Published var sourceWindow: SCWindow?
    @Published var sourceSnapshot: CGImage?

    var onConfirmFine: ((SCWindow, CGRect) -> Void)?  // window, rect
    var onCancel: (() -> Void)?
    var onAbort: (() -> Void)?

    private let userDefaults = UserDefaults.standard

    private enum Tuning {
        /// Minimum acceptable side length (window points) for any rectangle
        /// returned by the autofit detector or the centered default.
        static let minRectSide: CGFloat = 240
        /// Default and fallback rect aspect (modern video).
        static let videoAspectRatio: CGFloat = 16.0 / 9.0
        /// Vision rectangle-detector tuning.
        static let visionMinAspectRatio: Float = 0.4
        static let visionMaxAspectRatio: Float = 3.0
        static let visionMinSize: Float = 0.10
        static let visionMaxObservations: Int = 30
        static let visionMinConfidence: Float = 0.5
        static let visionQuadratureTolerance: Float = 25
        /// Bounding boxes covering ≥95% of both axes are basically the
        /// window itself — drop them.
        static let visionFullWindowThreshold: CGFloat = 0.95
        /// Cap the centered-default rect width so big monitors don't get
        /// an unreasonably large initial selection.
        static let centeredDefaultMaxWidth: CGFloat = 800
        /// Centered-default takes 50% of window width by default.
        static let centeredDefaultWidthFraction: CGFloat = 0.5
    }

    func start(window: SCWindow) {
        self.sourceWindow = window
        let size = window.frame.size

        if let savedFine = loadSavedFineRect(for: window) {
            self.fineRect = clampRect(savedFine, to: size)
        } else {
            self.fineRect = proposeLargestVideoRect(within: size)
        }

        self.sourceSnapshot = nil
        self.stage = .fine
        captureSnapshot(of: window)
    }

    /// Detects the largest plausible video rectangle inside the source window snapshot
    /// using Vision. Falls back to a centered default if nothing reasonable is found.
    func autofitVideoRect() {
        guard let win = sourceWindow else { return }
        guard let snapshot = sourceSnapshot else {
            useCenteredDefaultRect()
            return
        }

        let windowSize = win.frame.size

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = VNAspectRatio(Tuning.visionMinAspectRatio)
        request.maximumAspectRatio = VNAspectRatio(Tuning.visionMaxAspectRatio)
        request.minimumSize = Tuning.visionMinSize
        request.maximumObservations = Tuning.visionMaxObservations
        request.minimumConfidence = Tuning.visionMinConfidence
        request.quadratureTolerance = Tuning.visionQuadratureTolerance

        let handler = VNImageRequestHandler(cgImage: snapshot, options: [:])
        do {
            try handler.perform([request])
        } catch {
            useCenteredDefaultRect()
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            useCenteredDefaultRect()
            return
        }

        // Convert each observation's bounding box to source-window points (top-left origin).
        // Skip the full-window detection and anything below minRectSide.
        let candidates: [CGRect] = observations.compactMap { obs in
            let bb = obs.boundingBox
            if bb.width >= Tuning.visionFullWindowThreshold &&
               bb.height >= Tuning.visionFullWindowThreshold { return nil }
            let r = CGRect(
                x: bb.minX * windowSize.width,
                y: (1.0 - bb.maxY) * windowSize.height,
                width: bb.width * windowSize.width,
                height: bb.height * windowSize.height
            )
            if r.width < Tuning.minRectSide || r.height < Tuning.minRectSide { return nil }
            return r
        }

        if let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            fineRect = largest
        } else {
            useCenteredDefaultRect()
        }
    }

    /// Default centered rect when no autofit candidate is found. 16:9, 50% width.
    private func useCenteredDefaultRect() {
        guard let win = sourceWindow else { return }
        let windowSize = win.frame.size
        let preferredW: CGFloat = max(
            Tuning.minRectSide,
            min(windowSize.width * Tuning.centeredDefaultWidthFraction, Tuning.centeredDefaultMaxWidth)
        )
        let preferredH: CGFloat = max(Tuning.minRectSide, preferredW / Tuning.videoAspectRatio)
        let w = min(preferredW, windowSize.width)
        let h = min(preferredH, windowSize.height)
        let x = (windowSize.width - w) / 2
        let y = (windowSize.height - h) / 2
        fineRect = CGRect(x: x, y: y, width: w, height: h)
    }

    /// Confirms the chosen video region and goes straight to broadcasting.
    /// Source play/pause state will follow from the extension's reports;
    /// no calibration / initial-state prompt needed.
    func confirmFine() {
        guard stage == .fine, let win = sourceWindow else { return }
        saveFineRect(fineRect, for: win)
        stage = .broadcasting
        onConfirmFine?(win, fineRect)
    }

    func cancel() {
        let wasMid = stage != .idle
        resetState()
        if wasMid { onCancel?() }
    }

    func abort() {
        let wasMid = stage != .idle
        resetState()
        if wasMid { onAbort?() }
    }

    private func resetState() {
        stage = .idle
        sourceWindow = nil
        sourceSnapshot = nil
        fineRect = .zero
    }

    private func captureSnapshot(of window: SCWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.showsCursor = false
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        Task { @MainActor in
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                self.sourceSnapshot = image
            } catch {
                print("[wizard] snapshot capture failed: \(error)")
            }
        }
    }

    /// Largest 16:9 rectangle that fits inside the window, centered.
    private func proposeLargestVideoRect(within windowSize: CGSize) -> CGRect {
        let target = Tuning.videoAspectRatio
        let winAspect = windowSize.width / max(1, windowSize.height)
        var w: CGFloat
        var h: CGFloat
        if winAspect > target {
            h = windowSize.height
            w = h * target
        } else {
            w = windowSize.width
            h = w / target
        }
        let x = (windowSize.width - w) / 2
        let y = (windowSize.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Persistence

    private func storageKey(for window: SCWindow) -> String? {
        guard let bundleID = window.owningApplication?.bundleIdentifier else { return nil }
        return "wizardRects.\(bundleID)"
    }

    private func loadSavedFineRect(for window: SCWindow) -> CGRect? {
        guard let key = storageKey(for: window),
              let dict = userDefaults.dictionary(forKey: key) else { return nil }
        return decodeRect(dict["fine"])
    }

    private func saveFineRect(_ rect: CGRect, for window: SCWindow) {
        guard let key = storageKey(for: window) else { return }
        var dict = userDefaults.dictionary(forKey: key) ?? [:]
        dict["fine"] = ["x": rect.origin.x, "y": rect.origin.y, "w": rect.width, "h": rect.height]
        userDefaults.set(dict, forKey: key)
    }

    private func decodeRect(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Double],
              let x = dict["x"], let y = dict["y"],
              let w = dict["w"], let h = dict["h"], w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func clampRect(_ r: CGRect, to size: CGSize) -> CGRect {
        let w = min(r.width, size.width)
        let h = min(r.height, size.height)
        let x = max(0, min(size.width - w, r.origin.x))
        let y = max(0, min(size.height - h, r.origin.y))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
