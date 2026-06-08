import Foundation
import Combine

/// Bridge between the AppKit app and the Safari Web Extension.
/// Implements `VideoControlSource` — the cross-browser interface that
/// `PlayPauseCoordinator` uses to drive play/pause logic. A future
/// `ChromeExtensionBridge` will provide a parallel implementation.
///
/// **Mechanism**: shared files inside the App Group container, resolved
/// via `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`.
/// Both processes (the app and the extension's `SafariWebExtensionHandler`)
/// get the same path even though only the extension is sandboxed.
///
/// Why files instead of `UserDefaults(suiteName:)`: that API routes to
/// different physical plist files for sandboxed vs non-sandboxed processes
/// with the same App Group, so writes from the unsandboxed app never
/// become visible to the sandboxed handler.
///
/// Two files, one-writer ownership to avoid races:
///   - `command.json` — app writes, handler clears after processing
///   - `state.json`   — handler writes, app reads
///
/// Polling on both sides is intentional (handler is one-shot per native
/// message, so it can't push). 10 Hz on each side gives ~250 ms total
/// round-trip, well under the 5 s broadcast delay.
@MainActor
final class ExtensionBridge: ObservableObject, VideoControlSource {

    // MARK: - Public observable state

    @Published private(set) var observedSourcePlaying: Bool? = nil
    @Published private(set) var isAvailable: Bool = false

    /// Most recent state event from the extension (full payload, including
    /// the URL of the frame that owns the video). Currently only used by
    /// the dialog UI for the "Detected" indicator.
    @Published private(set) var observedState: VideoState?

    var observedSourcePlayingPublisher: AnyPublisher<Bool?, Never> {
        $observedSourcePlaying.eraseToAnyPublisher()
    }

    var isAvailablePublisher: AnyPublisher<Bool, Never> {
        $isAvailable.eraseToAnyPublisher()
    }

    struct VideoState: Equatable {
        let paused: Bool
        let frameURL: String
        let videoSrc: String
        let timestamp: Date
    }

    // MARK: - Private state

    /// Must match the App Group ID configured on both the main app and
    /// the extension target's "Signing & Capabilities" tab.
    private static let appGroupID = "group.com.barlr.AnimeAutoSubs"
    private static let commandFile = "command.json"
    private static let stateFile = "state.json"

    /// Frequency at which we re-read state.json. 10 Hz.
    private static let pollInterval: TimeInterval = 0.1

    private let containerURL: URL?
    private var pollTimer: Timer?
    private var lastObservedAt: Date?

    init() {
        self.containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
        if containerURL == nil {
            print("[bridge] WARNING: containerURL(forSecurityApplicationGroupIdentifier: \(Self.appGroupID)) returned nil. App Group entitlement not configured?")
        } else {
            print("[bridge] container: \(containerURL!.path)")
            // Clear any pending command left behind from a previous session
            // so launch doesn't auto-execute a stale toggle/play/pause.
            try? FileManager.default.removeItem(at: containerURL!.appendingPathComponent(Self.commandFile))
        }
        startPolling()
    }

    // MARK: - VideoControlSource

    func toggle() { writeCommand("toggle") }
    func play()   { writeCommand("play") }
    func pause()  { writeCommand("pause") }

    /// Force `observedSourcePlaying` to refresh from disk.
    func refresh() { tickState() }

    // MARK: - Internals

    private func writeCommand(_ command: String) {
        guard let url = commandURL() else { return }
        let id = UUID().uuidString
        let payload: [String: Any] = ["id": id, "command": command]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            try data.write(to: url, options: .atomic)
            print("[bridge] queued \(command) id=\(id)")
        } catch {
            print("[bridge] failed to write command.json: \(error)")
        }
    }

    private func commandURL() -> URL? {
        containerURL?.appendingPathComponent(Self.commandFile)
    }

    private func stateURL() -> URL? {
        containerURL?.appendingPathComponent(Self.stateFile)
    }

    private func startPolling() {
        tickState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickState()
            }
        }
    }

    private func tickState() {
        guard let url = stateURL(),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paused = dict["paused"] as? Bool,
              let href = dict["href"] as? String else {
            updateAvailability()
            return
        }
        let src = dict["src"] as? String ?? ""
        let candidate = VideoState(paused: paused, frameURL: href, videoSrc: src, timestamp: Date())

        if observedState != candidate {
            observedState = candidate
            lastObservedAt = candidate.timestamp
        }
        // observedSourcePlaying is the inverse of paused. Publish even if
        // the full state struct hasn't changed (e.g. only timestamp refresh)
        // so coordinators get the latest @Published value.
        let nowPlaying: Bool? = !paused
        if observedSourcePlaying != nowPlaying {
            observedSourcePlaying = nowPlaying
        }
        updateAvailability()
    }

    private func updateAvailability() {
        // Latch: once we've observed any state event, the extension is
        // considered available for the rest of the session. The previous
        // implementation expired availability after a freshness window,
        // which broke as soon as the video sat in the same play/pause
        // state for longer than the window — state events only fire on
        // transitions, so steady-state silence would falsely flag the
        // extension as unavailable and gate the dialog Play/Pause button.
        if lastObservedAt != nil && !isAvailable {
            isAvailable = true
        }
    }
}

extension ExtensionBridge.VideoState {
    static func == (lhs: ExtensionBridge.VideoState, rhs: ExtensionBridge.VideoState) -> Bool {
        // Equate on content (paused/href/src), not timestamp — otherwise
        // every poll tick republishes and re-renders SwiftUI views.
        return lhs.paused == rhs.paused
            && lhs.frameURL == rhs.frameURL
            && lhs.videoSrc == rhs.videoSrc
    }
}
