import Foundation
import Combine

/// Abstraction over "something that can observe and control a single
/// `<video>` element". Today this is implemented only by the Safari Web
/// Extension bridge (`ExtensionBridge`). When we add Chrome support, a
/// `ChromeExtensionBridge` will provide a parallel implementation, and
/// `PlayPauseCoordinator` will pick whichever is available.
///
/// The contract:
/// - State is observed asynchronously: each control source watches for
///   `play` / `pause` events on the underlying media element and
///   publishes them via `observedSourcePlayingPublisher`. Subscribers
///   are notified whenever the source's state changes (including
///   external changes — manual click on the player UI, popup toggle).
/// - Commands are best-effort and asynchronous. `play()`, `pause()`,
///   `toggle()` enqueue a command for the underlying transport (file
///   IPC + extension polling for Safari). The actual mutation happens
///   on the source page when the command lands.
/// - `isAvailable` is true iff a state event has been observed
///   recently (within an implementation-defined freshness window). It
///   tells the coordinator whether commands have any chance of
///   landing — e.g. the Safari extension is enabled and the active
///   tab has a video.
protocol VideoControlSource: AnyObject {

    /// Most recent observed state of the source video. `nil` until the
    /// first event arrives. `true` = playing, `false` = paused.
    var observedSourcePlaying: Bool? { get }

    /// True iff a state event has been observed within the implementation's
    /// freshness window. Coordinators should consider commands a no-op when
    /// `isAvailable` is false (the user might be on a page without a video,
    /// or the extension might be disabled).
    var isAvailable: Bool { get }

    /// Combine publisher for `observedSourcePlaying`. Coordinators sink
    /// on this to react to source-state changes.
    var observedSourcePlayingPublisher: AnyPublisher<Bool?, Never> { get }

    /// Combine publisher for `isAvailable`.
    var isAvailablePublisher: AnyPublisher<Bool, Never> { get }

    /// Live source-video playback position, in seconds.
    var sourceCurrentTime: Double { get }
    var sourceCurrentTimePublisher: AnyPublisher<Double, Never> { get }

    /// Source-video duration, in seconds. Zero if not yet known.
    var sourceDuration: Double { get }
    var sourceDurationPublisher: AnyPublisher<Double, Never> { get }

    /// Fires whenever this source issues a seek/skip command. Subscribers
    /// (typically the coordinator) react by flushing downstream buffers.
    var sourceDidSeekPublisher: AnyPublisher<Void, Never> { get }

    /// Send a command to the source video. The mutation is asynchronous —
    /// observe `observedSourcePlaying` to know when it took effect.
    func play()
    func pause()
    func toggle()

    /// Jump the source to an absolute time in seconds. Implementations
    /// should clamp to `[0, duration]`.
    func seek(to time: Double)

    /// Advance/rewind the source by `delta` seconds (negative rewinds).
    /// Implementations should clamp to `[0, duration]`.
    func skip(by delta: Double)
}
