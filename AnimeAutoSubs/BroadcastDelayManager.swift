import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreImage
import Metal
import AppKit
import Combine

/// Owns the capture stream, the buffer queue, the playback pump, and the audio engine.
///
/// Lifecycle: `start()` → `mode = .starting` → `.buffering(progress)` → `.playing`.
/// On `stop()`, the audio engine is torn down and the BlackHole routing is restored.
final class BroadcastDelayManager: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    enum Mode: Equatable {
        case idle
        case starting
        case buffering(progress: Double)
        case playing
        case stopping
    }

    enum CaptureQuality: String, CaseIterable {
        case standard = "Standard"
        case performance = "Performance"

        var scale: CGFloat {
            switch self {
            case .standard: return 1.0
            case .performance: return 0.5
            }
        }
    }

    /// Trade subtitle freshness for CPU pressure. Picks both how many
    /// whisper subprocesses run in parallel and how many cores each one
    /// uses. The whisper subprocess is by far the dominant CPU consumer
    /// in the app, so this knob is the easiest one to feel.
    enum TranscriptionLoad: String, CaseIterable {
        case light = "Light"
        case balanced = "Balanced"
        case maximum = "Maximum"

        /// Max concurrent whisper invocations. 2-3 saturates an 8-core M1.
        var concurrency: Int {
            switch self {
            case .light: return 1
            case .balanced: return 2
            case .maximum: return 3
            }
        }

        /// Threads handed to each whisper-cli (`-t` flag). 4 is the
        /// whisper-cpp default and best per-process throughput; lowering
        /// reduces oversubscription when multiple are in flight.
        var threadsPerProcess: Int {
            switch self {
            case .light: return 2
            case .balanced: return 4
            case .maximum: return 4
            }
        }
    }

    // MARK: - Tuning

    /// Capture-side tuning constants kept private to this file.
    private enum Tuning {
        /// Cap capture at this frame rate (per ScreenCaptureKit).
        static let maxCaptureFPS: Int32 = 30
        /// SC stream buffer depth; ample headroom for short stalls.
        static let captureQueueDepth: Int = 60
        /// SC audio capture rate. Downsampled internally for whisper.
        static let captureAudioSampleRate: Int = 48_000
        static let captureAudioChannels: Int = 2

        /// How often Vision text-detection runs while broadcasting (seconds between requests).
        static let visionDetectInterval: CFTimeInterval = 0.2  // ~5Hz with .fast mode

        /// Vision is run on a frame still buffered in the queue, this far ahead of
        /// being displayed. A typical detection takes ~0.2-0.3s, so 0.5s of slack
        /// means the rects are ready by the time the frame is pumped to the layer.
        /// The total broadcast delay is unchanged (still `delaySeconds`) — we just
        /// reuse the tail end of the buffer for detection.
        static let visionLookaheadSeconds: CFTimeInterval = 0.5

        /// How early to publish rects vs. the matching frame's emission. Compensates
        /// for the dispatch-to-main + SwiftUI invalidate latency (~80ms in practice)
        /// so the blur lands on screen at the same compositor cycle as the frame.
        static let visionActivationLeadSeconds: CFTimeInterval = 0.08
    }

    // MARK: - Published state

    @Published private(set) var mode: Mode = .idle
    @Published var delaySeconds: Double = BroadcastConstants.defaultDelaySeconds {
        didSet {
            UserDefaults.standard.set(delaySeconds, forKey: "broadcastDelaySeconds")
            // Changing the delay invalidates the current buffer — re-warmup with the new delay.
            if engineSetupComplete && oldValue != delaySeconds {
                rewarmupForDelayChange()
            }
        }
    }
    @Published private(set) var sourceWindowSize: CGSize = .zero
    @Published var blurEnglishSubtitles: Bool = false {
        didSet { UserDefaults.standard.set(blurEnglishSubtitles, forKey: "blurEnglishSubtitles") }
    }
    /// Point size of the Japanese subtitle (main glyph). Furigana scales proportionally.
    @Published var subtitleFontSize: Double = 32 {
        didSet { UserDefaults.standard.set(subtitleFontSize, forKey: "subtitleFontSize") }
    }
    @Published var captureQuality: CaptureQuality = .standard {
        didSet { UserDefaults.standard.set(captureQuality.rawValue, forKey: "captureQuality") }
    }
    @Published var transcriptionLoad: TranscriptionLoad = .balanced {
        didSet { UserDefaults.standard.set(transcriptionLoad.rawValue, forKey: "transcriptionLoad") }
    }
    @Published var outputVolume: Float = 1.0 {
        didSet {
            applyVolume()
            UserDefaults.standard.set(outputVolume, forKey: "broadcastOutputVolume")
        }
    }

    @Published var isPaused: Bool = false
    @Published private(set) var hasEverEmittedFrame: Bool = false
    /// Detected English-text rects in normalized (0..1) Vision coordinates (origin bottom-left).
    @Published private(set) var detectedSubtitleRects: [CGRect] = []

    @Published private(set) var engineSetupComplete = false
    /// Name of the audio output device the playback engine is currently routed to.
    /// Surfaced in the broadcast control so the user can quickly tell if delayed
    /// audio is going somewhere they can hear (vs. e.g. dead AirPods).
    @Published private(set) var outputRouteName: String?

    let videoLayer = CALayer()

    var onSpeechSegmentReady: (([Float], CFTimeInterval) -> Void)?

    var preferredOutputDeviceID: AudioObjectID?
    private var savedDefaultOutputDevice: AudioObjectID?

    /// Device ID currently receiving the delayed audio. Tracked so the global
    /// media-key tap can adjust *this* device's hardware volume — the system
    /// default during broadcast is BlackHole, so volume keys would otherwise
    /// crank a silent device.
    @Published private(set) var currentBroadcastOutputDeviceID: AudioObjectID?

    // MARK: - Private state

    private let captureQueue = DispatchQueue(label: "broadcast.capture.video", qos: .userInteractive)
    private let audioCaptureQueue = DispatchQueue(label: "broadcast.capture.audio", qos: .userInteractive)
    private let pumpQueue = DispatchQueue(label: "broadcast.pump", qos: .userInteractive)
    private var pumpSource: DispatchSourceTimer?

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private var stream: SCStream?

    private struct VideoEntry { let image: CGImage; let captureTime: CFTimeInterval }
    private struct AudioEntry { let pcm: AVAudioPCMBuffer; let captureTime: CFTimeInterval }

    private var videoQueue: [VideoEntry] = []
    private var audioQueue: [AudioEntry] = []
    private let queueLock = NSLock()

    private var captureStartTime: CFTimeInterval?
    private var hasStartedPlayback = false

    private var pauseStartTime: CFTimeInterval?

    /// Linked-list of SCStream lifecycle operations (stop/start). Each new
    /// call appends to the chain, awaiting the previous task so back-to-back
    /// pause/resume toggles execute serially against the framework rather
    /// than racing.
    private var streamLifecycleTask: Task<Void, Never>?

    // Vision text detection — runs on frames that are still `visionLookaheadSeconds`
    // away from being displayed. Results are queued in pendingRects and activated
    // when the matching frame is pumped to the layer.
    private var lastVisionRequestAt: CFTimeInterval = 0
    private let textDetector = EnglishTextDetector()
    private struct PendingRects {
        let activationCaptureTime: CFTimeInterval
        let rects: [CGRect]
    }
    private var pendingRects: [PendingRects] = []
    private let pendingRectsLock = NSLock()

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Inserted between playerNode and mainMixerNode so the volume slider can
    /// go above unity. mainMixerNode.outputVolume is clamped to [0, 1]; the
    /// EQ's globalGain (in dB) handles the boost above 100%.
    private let gainEQ = AVAudioUnitEQ(numberOfBands: 1)
    private var captureAudioFormat: AVAudioFormat?

    private let speechSegmenter = SpeechSegmenter()

    // MARK: - Init

    override init() {
        super.init()
        setupDisplayLayer()
        audioEngine.attach(playerNode)
        audioEngine.attach(gainEQ)
        loadPersistedSettings()

        speechSegmenter.onSegmentReady = { [weak self] samples, segmentStartTime in
            self?.onSpeechSegmentReady?(samples, segmentStartTime)
        }
        textDetector.onRectsUpdated = { [weak self] rects, activationCaptureTime in
            guard let self = self else { return }
            self.pendingRectsLock.lock()
            // Back-date non-empty detections by one detection interval. Rationale:
            // Vision runs at ~5Hz, so a subtitle could have appeared any time
            // between the previous check and this one. Activating the rects from
            // the earlier moment makes the blur cover those in-between frames too.
            // The visual cost is "blur appears on a frame slightly before the text
            // does" — but the text is about to appear in the same spot, so it
            // looks like the blur was perfectly anticipatory.
            let backDate = rects.isEmpty ? 0 : Tuning.visionDetectInterval
            self.pendingRects.append(PendingRects(
                activationCaptureTime: activationCaptureTime - backDate,
                rects: rects
            ))
            self.pendingRects.sort { $0.activationCaptureTime < $1.activationCaptureTime }
            self.pendingRectsLock.unlock()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioEngineConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    private func loadPersistedSettings() {
        if let savedVolume = UserDefaults.standard.object(forKey: "broadcastOutputVolume") as? Float,
           BroadcastConstants.volumeRange.contains(savedVolume) {
            outputVolume = savedVolume
        }
        if let savedDelay = UserDefaults.standard.object(forKey: "broadcastDelaySeconds") as? Double,
           BroadcastConstants.delaySecondsRange.contains(savedDelay) {
            delaySeconds = savedDelay
        }
        if let qualityRaw = UserDefaults.standard.string(forKey: "captureQuality"),
           let q = CaptureQuality(rawValue: qualityRaw) {
            captureQuality = q
        }
        if let loadRaw = UserDefaults.standard.string(forKey: "transcriptionLoad"),
           let load = TranscriptionLoad(rawValue: loadRaw) {
            transcriptionLoad = load
        }
        blurEnglishSubtitles = UserDefaults.standard.bool(forKey: "blurEnglishSubtitles")
        if let fs = UserDefaults.standard.object(forKey: "subtitleFontSize") as? Double,
           BroadcastConstants.subtitleFontSizeRange.contains(fs) {
            subtitleFontSize = fs
        }
    }

    private func setupDisplayLayer() {
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resizeAspectFill
        videoLayer.actions = ["contents": NSNull()]
        videoLayer.masksToBounds = true
    }

    // MARK: - Lifecycle

    func start(window: SCWindow, sourceRect: CGRect? = nil, initialIsPaused: Bool = false) async throws {
        await MainActor.run {
            self.mode = .starting
            let effective = sourceRect ?? CGRect(origin: .zero, size: window.frame.size)
            self.sourceWindowSize = effective.size
            self.isPaused = initialIsPaused
        }

        switchSystemDefaultToBlackHole()

        let stream = try await makeAndStartStream(window: window, sourceRect: sourceRect)
        self.stream = stream

        await MainActor.run {
            self.captureStartTime = CACurrentMediaTime()
            self.hasStartedPlayback = false
            self.mode = .buffering(progress: 0)
            self.startPump()
        }
    }

    func stop() async {
        await MainActor.run { self.mode = .stopping }
        restoreSavedOutputDevice()

        do { try await stream?.stopCapture() } catch { }
        stream = nil
        await MainActor.run {
            self.pumpSource?.cancel()
            self.pumpSource = nil
            self.playerNode.stop()
            self.audioEngine.stop()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.videoLayer.contents = nil
            CATransaction.commit()

            self.queueLock.lock()
            self.videoQueue.removeAll()
            self.audioQueue.removeAll()
            self.queueLock.unlock()

            self.pendingRectsLock.lock()
            self.pendingRects.removeAll()
            self.pendingRectsLock.unlock()

            self.speechSegmenter.reset()

            self.captureStartTime = nil
            self.hasStartedPlayback = false
            self.engineSetupComplete = false
            self.outputRouteName = nil
            self.currentBroadcastOutputDeviceID = nil
            self.captureAudioFormat = nil
            self.isPaused = false
            self.pauseStartTime = nil
            self.hasEverEmittedFrame = false
            self.videoLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            self.mode = .idle
        }
    }

    // MARK: - Pause/Resume

    /// Pause: instant freeze of both output (pump gated) and audio, plus an
    /// async `SCStream.stopCapture` so we stop encoding source frames we'd
    /// just discard. The source-side pause is the caller's responsibility —
    /// the AppDelegate dispatches a synthetic click at the calibrated
    /// play-button position.
    func pause() {
        guard engineSetupComplete else { return }
        isPaused = true
        pauseStartTime = CACurrentMediaTime()
        playerNode.pause()
        // Drop any in-progress VAD segment — its samples and start-time are
        // about to be separated by an arbitrary pause duration, so stitching
        // them with post-resume audio would produce a broken transcript.
        speechSegmenter.reset()
        queueStreamLifecycle { try await $0.stopCapture() }
    }

    /// Resume: if buffer has pre-pause active content, shift captureTimes for instant smooth resume.
    /// If buffer is empty (initial pause case), restart warmup so the user sees a Buffering UI then fresh content.
    /// Also kicks off `SCStream.startCapture` (async, ~100-500 ms before first frame arrives — hidden by the
    /// buffered content already playing through, or by the empty-buffer warmup).
    func resume() {
        guard engineSetupComplete else { return }

        queueStreamLifecycle { try await $0.startCapture() }

        queueLock.lock()
        let isQueueEmpty = videoQueue.isEmpty
        queueLock.unlock()

        if isQueueEmpty {
            // Empty buffer (likely initial pause). Restart warmup with fresh capture.
            captureStartTime = CACurrentMediaTime()
            hasStartedPlayback = false
            isPaused = false
            mode = .buffering(progress: 0)
            if audioEngine.isRunning {
                playerNode.play()
            }
            return
        }

        guard let pStart = pauseStartTime else {
            isPaused = false
            playerNode.play()
            return
        }
        let now = CACurrentMediaTime()
        let pausedDuration = now - pStart

        queueLock.lock()
        videoQueue.removeAll { $0.captureTime >= pStart }
        audioQueue.removeAll { $0.captureTime >= pStart }
        for i in videoQueue.indices {
            videoQueue[i] = VideoEntry(image: videoQueue[i].image,
                                       captureTime: videoQueue[i].captureTime + pausedDuration)
        }
        for i in audioQueue.indices {
            audioQueue[i] = AudioEntry(pcm: audioQueue[i].pcm,
                                       captureTime: audioQueue[i].captureTime + pausedDuration)
        }
        queueLock.unlock()

        pauseStartTime = nil
        isPaused = false
        playerNode.play()
    }

    /// Append an SCStream lifecycle operation to the serial chain. Each
    /// task waits for the previous one to complete before invoking the
    /// framework, so rapid pause→resume sequences don't race
    /// `stopCapture` against an already-in-flight `startCapture`.
    private func queueStreamLifecycle(_ op: @escaping (SCStream) async throws -> Void) {
        let previous = streamLifecycleTask
        streamLifecycleTask = Task { [weak self] in
            await previous?.value
            guard let stream = self?.stream else { return }
            do {
                try await op(stream)
            } catch {
                print("[broadcast] stream lifecycle op failed: \(error)")
            }
        }
    }

    /// Manually correct the app's belief of source state (does NOT send a
    /// click to the source). Used by the source-state probe's auto-correct
    /// path and by the dialog's manual Toggle button.
    func syncToggle() {
        isPaused.toggle()
        if isPaused {
            pauseStartTime = CACurrentMediaTime()
            playerNode.pause()
        } else {
            pauseStartTime = nil
            if audioEngine.isRunning { playerNode.play() }
        }
    }

    // MARK: - Audio routing

    /// Switch system default to BlackHole so the source app's audio is silenced (still captured per-process).
    private func switchSystemDefaultToBlackHole() {
        guard let blackhole = AudioDeviceManager.shared.findBlackHole(),
              let currentID = AudioDeviceManager.shared.currentDefaultOutputDevice() else { return }
        let allDevices = AudioDeviceManager.shared.listOutputDevices()
        if let currentDevice = allDevices.first(where: { $0.id == currentID }),
           !currentDevice.isBlackHole {
            // Only save the "current" device if it's not already BlackHole (avoid trapping ourselves on BlackHole).
            self.savedDefaultOutputDevice = currentID
            UserDefaults.standard.set(currentDevice.uid, forKey: "savedDefaultOutputDeviceUID")
        }
        AudioDeviceManager.shared.setDefaultOutputDevice(blackhole.id)
    }

    /// Restores the system default output device to whatever was active before broadcasting,
    /// using either the in-memory value or the persisted UID (for crash recovery).
    func restoreSavedOutputDevice() {
        if let saved = savedDefaultOutputDevice {
            AudioDeviceManager.shared.setDefaultOutputDevice(saved)
            savedDefaultOutputDevice = nil
            UserDefaults.standard.removeObject(forKey: "savedDefaultOutputDeviceUID")
            return
        }
        if let uid = UserDefaults.standard.string(forKey: "savedDefaultOutputDeviceUID"),
           let device = AudioDeviceManager.shared.device(matching: uid) {
            AudioDeviceManager.shared.setDefaultOutputDevice(device.id)
            UserDefaults.standard.removeObject(forKey: "savedDefaultOutputDeviceUID")
        }
    }

    // MARK: - Capture stream setup

    private func makeAndStartStream(window: SCWindow, sourceRect: CGRect?) async throws -> SCStream {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        let captureSize: CGSize
        if let rect = sourceRect {
            captureSize = rect.size
            config.sourceRect = rect
        } else {
            captureSize = window.frame.size
        }
        // Capture at 1x (window points), not retina pixels. Display layer scales.
        let qualityScale = captureQuality.scale
        config.width = max(2, Int(captureSize.width * qualityScale))
        config.height = max(2, Int(captureSize.height * qualityScale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: Tuning.maxCaptureFPS)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = Tuning.captureQueueDepth
        config.showsCursor = false
        config.scalesToFit = true

        config.capturesAudio = true
        config.sampleRate = Tuning.captureAudioSampleRate
        config.channelCount = Tuning.captureAudioChannels

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioCaptureQueue)
        try await stream.startCapture()
        return stream
    }

    // MARK: - Playback pump

    private func startPump() {
        pumpSource?.cancel()
        let source = DispatchSource.makeTimerSource(queue: pumpQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(BroadcastConstants.pumpTickMilliseconds))
        source.setEventHandler { [weak self] in self?.pumpTick() }
        source.resume()
        pumpSource = source
    }

    private func pumpTick() {
        guard let captureStart = captureStartTime else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - captureStart

        queueLock.lock()
        let started = hasStartedPlayback
        queueLock.unlock()

        if !started {
            if elapsed >= delaySeconds {
                queueLock.lock()
                hasStartedPlayback = true
                queueLock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.beginPlaybackPhase()
                }
            } else {
                let progress = min(elapsed / delaySeconds, 1.0)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if case .buffering = self.mode {
                        self.mode = .buffering(progress: progress)
                    }
                }
                return
            }
        }

        if isPaused { return }

        let cutoff = now - delaySeconds

        queueLock.lock()
        var videoToEmit: [VideoEntry] = []
        while let first = videoQueue.first, first.captureTime <= cutoff {
            videoToEmit.append(first)
            videoQueue.removeFirst()
        }
        var audioToEmit: [AVAudioPCMBuffer] = []
        while let first = audioQueue.first, first.captureTime <= cutoff {
            audioToEmit.append(first.pcm)
            audioQueue.removeFirst()
        }
        // Snapshot lookahead frame for vision detection (the frame that will be
        // displayed `visionLookaheadSeconds` from now).
        let lookaheadTarget = now - delaySeconds + Tuning.visionLookaheadSeconds
        let lookaheadFrame = videoQueue.first(where: { $0.captureTime >= lookaheadTarget })
        queueLock.unlock()

        for entry in videoToEmit {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.contents = entry.image
            CATransaction.commit()
            if !hasEverEmittedFrame {
                DispatchQueue.main.async { [weak self] in self?.hasEverEmittedFrame = true }
            }
            activatePendingRects(for: entry.captureTime)
        }
        for pcm in audioToEmit {
            playerNode.scheduleBuffer(pcm, completionHandler: nil)
        }

        scheduleVisionDetectionIfNeeded(now: now, lookaheadFrame: lookaheadFrame)
    }

    /// Find the latest pending rects whose activation time has been reached by
    /// the just-emitted frame, and publish them. Discard older entries.
    private func activatePendingRects(for emittedCaptureTime: CFTimeInterval) {
        var applied: [CGRect]?
        // Activate slightly EARLIER than the matching frame to compensate for the
        // dispatch-to-main + SwiftUI re-render latency. Without this lead, the blur
        // visibly lags the frame by 1-2 compositor cycles.
        let threshold = emittedCaptureTime + Tuning.visionActivationLeadSeconds
        pendingRectsLock.lock()
        while let first = pendingRects.first, first.activationCaptureTime <= threshold {
            applied = first.rects
            pendingRects.removeFirst()
        }
        pendingRectsLock.unlock()
        guard let r = applied else { return }
        DispatchQueue.main.async { [weak self] in
            self?.detectedSubtitleRects = r
        }
    }

    private func scheduleVisionDetectionIfNeeded(now: CFTimeInterval, lookaheadFrame: VideoEntry?) {
        if !blurEnglishSubtitles {
            if !detectedSubtitleRects.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.detectedSubtitleRects = [] }
            }
            pendingRectsLock.lock()
            pendingRects.removeAll()
            pendingRectsLock.unlock()
            return
        }
        guard now - lastVisionRequestAt >= Tuning.visionDetectInterval,
              let frame = lookaheadFrame else { return }
        lastVisionRequestAt = now
        textDetector.submit(frame.image, captureTime: frame.captureTime)
    }

    // MARK: - Audio engine

    @MainActor
    private func beginPlaybackPhase() {
        if !audioEngine.isRunning, let format = captureAudioFormat {
            // playerNode → gainEQ → mainMixerNode → outputNode. The EQ lets us
            // push past unity gain when the slider is above 100%.
            audioEngine.connect(playerNode, to: gainEQ, format: format)
            audioEngine.connect(gainEQ, to: audioEngine.mainMixerNode, format: format)
            // Set output device BEFORE starting the engine — setting CurrentDevice on a running
            // engine triggers a configuration-change that stops it.
            //
            // If the user's preferred device fails to apply (e.g., it's a UID
            // for an output that just got disconnected), retry with the
            // built-in fallback so we still get audible output.
            let primary = preferredOutputDeviceID ?? findFallbackOutputDevice()
            if let device = primary, !applyOutputDevice(device) {
                if let backup = findFallbackOutputDevice(), backup != device {
                    _ = applyOutputDevice(backup)
                }
            } else if primary == nil {
                print("[audio] no usable output device found")
            }
            do {
                try audioEngine.start()
                applyVolume()
                playerNode.play()
                engineSetupComplete = true
            } catch {
                print("[audio] engine.start() failed: \(error)")
            }
        }
        self.mode = .playing
    }

    /// Translates the user's 0–2 slider into the two-stage volume pipeline:
    ///   • mainMixerNode.outputVolume covers the linear 0–1 region (silent → unity).
    ///   • gainEQ.globalGain (dB) handles the boost above unity.
    /// Setting both whenever the slider moves keeps the chain consistent
    /// regardless of which region the user lands in.
    private func applyVolume() {
        let v = outputVolume
        audioEngine.mainMixerNode.outputVolume = min(1.0, v)
        gainEQ.globalGain = v > 1.0 ? 20 * log10f(v) : 0
    }

    private func findFallbackOutputDevice() -> AudioObjectID? {
        let devices = AudioDeviceManager.shared.listOutputDevices().filter { !$0.isBlackHole }
        if let builtIn = devices.first(where: { $0.name.lowercased().contains("built-in") || $0.name.lowercased().contains("macbook") }) {
            return builtIn.id
        }
        return devices.first?.id
    }

    private func rewarmupForDelayChange() {
        queueLock.lock()
        videoQueue.removeAll()
        audioQueue.removeAll()
        queueLock.unlock()
        captureStartTime = CACurrentMediaTime()
        hasStartedPlayback = false
        mode = .buffering(progress: 0)
    }

    @objc private func audioEngineConfigurationChanged(_ notification: Notification) {
        // Don't auto-restart until beginPlaybackPhase has finished its initial setup.
        guard engineSetupComplete, !audioEngine.isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.engineSetupComplete, !self.audioEngine.isRunning else { return }
            do {
                try self.audioEngine.start()
                self.playerNode.play()
            } catch {
                print("[audio] AudioEngine restart after config change failed: \(error)")
            }
        }
    }

    @discardableResult
    private func applyOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        guard let outAU = audioEngine.outputNode.audioUnit else {
            print("[audio] outputNode.audioUnit is nil")
            outputRouteName = nil
            currentBroadcastOutputDeviceID = nil
            return false
        }
        var devID = deviceID
        let status = AudioUnitSetProperty(
            outAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("[audio] AudioUnitSetProperty(CurrentDevice=\(deviceID)) failed: status=\(status)")
            outputRouteName = nil
            currentBroadcastOutputDeviceID = nil
            return false
        }
        let name = AudioDeviceManager.shared.listOutputDevices()
            .first(where: { $0.id == deviceID })?.name
        outputRouteName = name
        currentBroadcastOutputDeviceID = deviceID
        return true
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[broadcast] stream stopped: \(error)")
        Task { @MainActor in self.mode = .idle }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        if isPaused { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }

        // Convert immediately so the IOSurface backing is released and SC can keep producing.
        guard let cgImage = makeCGImage(from: pixelBuffer) else { return }

        let now = CACurrentMediaTime()
        queueLock.lock()
        videoQueue.append(VideoEntry(image: cgImage, captureTime: now))
        queueLock.unlock()
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let pcm = CMSampleBufferToPCMBuffer(sb) else { return }

        // Always capture the audio format on first sample, even during pause —
        // beginPlaybackPhase needs it to set up the engine, and we want the engine to be
        // ready (and the button enabled) regardless of initial pause state.
        if captureAudioFormat == nil {
            captureAudioFormat = pcm.format
            if isPaused {
                // Initial-paused: skip the warmup wait, set up the engine immediately.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.queueLock.lock()
                    self.hasStartedPlayback = true
                    self.queueLock.unlock()
                    self.beginPlaybackPhase()
                }
            }
        }

        if isPaused { return }

        speechSegmenter.feed(pcm)

        let now = CACurrentMediaTime()
        queueLock.lock()
        audioQueue.append(AudioEntry(pcm: pcm, captureTime: now))
        queueLock.unlock()
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

func CMSampleBufferToPCMBuffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sb),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }

    var asbd = asbdPtr.pointee
    guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
    guard frameCount > 0,
          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
    pcm.frameLength = frameCount

    let err = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sb,
        at: 0,
        frameCount: Int32(frameCount),
        into: pcm.mutableAudioBufferList
    )
    if err != noErr { return nil }
    return pcm
}
