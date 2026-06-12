import Foundation
import Combine

/// Bridge that talks to a browser extension over HTTP via
/// `LocalControlServer` (no file IPC, no native-messaging handler).
/// One instance per browser identifier — e.g. one for Safari, one for
/// Chrome. Both implement `VideoControlSource` the same way and route
/// through `MediaSourceRouter`, so downstream code (coordinator, UI)
/// can't tell them apart.
///
/// Compared with the file-IPC `ExtensionBridge`, the responsibilities
/// invert: instead of polling a file for state, this bridge waits for
/// the server to call `receiveState(_:)` when an extension POSTs to
/// `/state`. Instead of writing commands to a file, it appends them to
/// an in-memory queue that the server drains via `popNextCommand()`
/// when the extension hits `/poll`.
@MainActor
final class HTTPExtensionBridge: ObservableObject, VideoControlSource {

    // MARK: - Public observable state

    @Published private(set) var observedSourcePlaying: Bool? = nil
    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var sourceCurrentTime: Double = 0
    @Published private(set) var sourceDuration: Double = 0

    let sourceDidSeek = PassthroughSubject<Void, Never>()

    var observedSourcePlayingPublisher: AnyPublisher<Bool?, Never> {
        $observedSourcePlaying.eraseToAnyPublisher()
    }
    var isAvailablePublisher: AnyPublisher<Bool, Never> {
        $isAvailable.eraseToAnyPublisher()
    }
    var sourceCurrentTimePublisher: AnyPublisher<Double, Never> {
        $sourceCurrentTime.eraseToAnyPublisher()
    }
    var sourceDurationPublisher: AnyPublisher<Double, Never> {
        $sourceDuration.eraseToAnyPublisher()
    }
    var sourceDidSeekPublisher: AnyPublisher<Void, Never> {
        sourceDidSeek.eraseToAnyPublisher()
    }

    let browserName: String

    // MARK: - Private state

    private var commandQueue: [[String: Any]] = []
    private var lastObservedAt: Date?

    init(browserName: String, server: LocalControlServer) {
        self.browserName = browserName
        server.register(self, for: browserName)
    }

    // MARK: - VideoControlSource (commands → queue, drained by /poll)

    func toggle() { queueCommand("toggle") }
    func play()   { queueCommand("play") }
    func pause()  { queueCommand("pause") }

    func seek(to time: Double) {
        queueCommand("seek", extras: ["time": time])
        sourceDidSeek.send()
    }

    func skip(by delta: Double) {
        queueCommand("skip", extras: ["delta": delta])
        sourceDidSeek.send()
    }

    private func queueCommand(_ command: String, extras: [String: Any] = [:]) {
        let id = UUID().uuidString
        var payload: [String: Any] = ["id": id, "command": command]
        for (k, v) in extras { payload[k] = v }
        commandQueue.append(payload)
        if extras.isEmpty {
            print("[bridge-\(browserName)] queued \(command) id=\(id)")
        } else {
            print("[bridge-\(browserName)] queued \(command) id=\(id) \(extras)")
        }
    }

    /// Called by `LocalControlServer` (on the main actor) when the
    /// extension issues `GET /poll?browser=<name>`. Returns the oldest
    /// queued command, or `nil` if the queue is empty.
    func popNextCommand() -> [String: Any]? {
        if commandQueue.isEmpty { return nil }
        return commandQueue.removeFirst()
    }

    // MARK: - State events from the extension

    /// Called by `LocalControlServer` (on the main actor) when the
    /// extension posts `/state`. Mirrors the parsing in
    /// `ExtensionBridge.tickState()` for the same JSON shape so both
    /// transports interoperate without the upstream UI noticing.
    func receiveState(_ dict: [String: Any]) {
        guard let paused = dict["paused"] as? Bool,
              let _ = dict["href"] as? String else {
            return
        }

        let nowPlaying: Bool? = !paused
        if observedSourcePlaying != nowPlaying {
            observedSourcePlaying = nowPlaying
        }

        if let t = dict["currentTime"] as? Double, abs(sourceCurrentTime - t) > 0.05 {
            sourceCurrentTime = t
        }
        if let d = dict["duration"] as? Double, abs(sourceDuration - d) > 0.05 {
            sourceDuration = d
        }

        lastObservedAt = Date()
        if !isAvailable { isAvailable = true }
    }
}
