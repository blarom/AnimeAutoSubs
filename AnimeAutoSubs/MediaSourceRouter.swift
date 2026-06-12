import Foundation
import Combine

/// Republishes the active `VideoControlSource`'s state and forwards
/// commands to it. UI layers bind to this single ObservableObject so
/// they don't depend on which concrete bridge is active for the current
/// broadcast — `WizardDialogView`, `BroadcastPlayerView`, and
/// `PlayPauseCoordinator` all see the same surface regardless of
/// transport (file IPC, HTTP) or browser (Safari, Chrome).
///
/// Lifecycle:
/// - Created once at app launch, lives for the app's lifetime.
/// - `setActive(bridge)` is called at the start of each broadcast with
///   the bridge chosen for the selected browser/transport, and
///   `setActive(nil)` at broadcast stop.
/// - Bridge subscriptions are torn down and re-established atomically
///   on each `setActive` call.
@MainActor
final class MediaSourceRouter: ObservableObject, VideoControlSource {

    // MARK: - Republished state (mirrors the active bridge)

    @Published private(set) var observedSourcePlaying: Bool? = nil
    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var sourceCurrentTime: Double = 0
    @Published private(set) var sourceDuration: Double = 0

    /// The currently-active concrete bridge. `nil` between broadcasts.
    /// Tests and diagnostics can read this; UI should not — bind to the
    /// republished `@Published` properties instead.
    private(set) var activeSource: VideoControlSource?

    private var bridgeCancellables: Set<AnyCancellable> = []
    private let seekSubject = PassthroughSubject<Void, Never>()

    // MARK: - VideoControlSource publishers

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
        seekSubject.eraseToAnyPublisher()
    }

    // MARK: - Active source management

    func setActive(_ source: VideoControlSource?) {
        bridgeCancellables.removeAll()
        activeSource = source

        guard let source = source else {
            // Reset republished state so the UI doesn't show stale values
            // from a previous broadcast.
            observedSourcePlaying = nil
            isAvailable = false
            sourceCurrentTime = 0
            sourceDuration = 0
            print("[media-source] active cleared")
            return
        }
        print("[media-source] active → \(type(of: source))")

        // Subscribing to a @Published fires the current value immediately,
        // so the router catches up to the bridge's latest state without
        // waiting for the next state event.
        source.observedSourcePlayingPublisher
            .sink { [weak self] in self?.observedSourcePlaying = $0 }
            .store(in: &bridgeCancellables)
        source.isAvailablePublisher
            .sink { [weak self] in self?.isAvailable = $0 }
            .store(in: &bridgeCancellables)
        source.sourceCurrentTimePublisher
            .sink { [weak self] in self?.sourceCurrentTime = $0 }
            .store(in: &bridgeCancellables)
        source.sourceDurationPublisher
            .sink { [weak self] in self?.sourceDuration = $0 }
            .store(in: &bridgeCancellables)
        source.sourceDidSeekPublisher
            .sink { [weak self] in self?.seekSubject.send() }
            .store(in: &bridgeCancellables)
    }

    // MARK: - VideoControlSource (forward to active)

    func toggle() { activeSource?.toggle() }
    func play()   { activeSource?.play() }
    func pause()  { activeSource?.pause() }
    func seek(to time: Double) { activeSource?.seek(to: time) }
    func skip(by delta: Double) { activeSource?.skip(by: delta) }
}
