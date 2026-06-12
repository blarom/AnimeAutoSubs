import Foundation
import Combine

/// The single play/pause brain.
///
/// **Single source of truth**: the actual `<video>` element's state, as
/// observed by the extension's content script. Broadcast state mirrors
/// the observed source state — never the other way around.
///
/// **Inputs**: any user-facing trigger (dialog Play/Pause button,
/// extension popup Toggle, manual click on the source player) ultimately
/// commands the source video. The video toggles, fires a play/pause
/// event, and the resulting state echoes back through the bridge. The
/// coordinator's sink updates broadcast state to match. One direction of
/// state flow, no feedback loops, no temporal gates.
///
/// **Initial state**: when broadcast starts, `enforceInitialPause()` is
/// called. The coordinator sends a `pause()` command to the source so
/// the user always begins from a known paused state, regardless of what
/// the source was doing.
///
/// **Buffering**: while broadcast is in `.buffering` mode, the
/// coordinator still aligns `isPaused` immediately. The pump won't
/// emit frames until warmup completes, but the published state is
/// accurate.
@MainActor
final class PlayPauseCoordinator {
    private let source: VideoControlSource
    private weak var broadcast: BroadcastDelayManager?
    private weak var subtitles: SubtitleManager?
    private var cancellables: Set<AnyCancellable> = []

    init(source: VideoControlSource,
         broadcast: BroadcastDelayManager,
         subtitles: SubtitleManager) {
        self.source = source
        self.broadcast = broadcast
        self.subtitles = subtitles
        wireUp()
    }

    private func wireUp() {
        source.observedSourcePlayingPublisher
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] sourcePlaying in
                self?.alignBroadcast(toSourcePlaying: sourcePlaying)
            }
            .store(in: &cancellables)

        // When the source seeks, the broadcast's buffered frames are at
        // the wrong media time — flush and re-warm, and drop any
        // already-visible subtitles since they belong to the pre-seek
        // playhead. In-flight whisper jobs from before the seek may still
        // produce one or two subtitles for the old position; they'll
        // expire naturally via the persistence timer.
        source.sourceDidSeekPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self = self else { return }
                print("[coordinator] source seeked → flushing broadcast buffer + subtitles")
                self.broadcast?.flushAndRebuffer()
                self.subtitles?.clear()
            }
            .store(in: &cancellables)
    }

    // MARK: - User-initiated commands

    /// User asked for a play/pause toggle (dialog button click). The
    /// command goes to the source. Broadcast aligns when the state
    /// echo arrives ~250 ms later.
    func userToggle() {
        source.toggle()
    }

    /// User asked to skip the source by `delta` seconds (negative rewinds).
    /// Broadcast buffer flushes via the `sourceDidSeek` subscription wired
    /// in `wireUp()`.
    func userSkip(by delta: Double) {
        source.skip(by: delta)
    }

    /// User asked to seek the source to an absolute media time (slider
    /// release). Broadcast flush handled via the subscription.
    func userSeek(to time: Double) {
        source.seek(to: time)
    }

    // MARK: - Lifecycle

    /// Called once when broadcast starts. Commands the source to pause
    /// so the user begins from a known state. If the source is already
    /// paused, no event fires and broadcast stays paused (where it
    /// started). If the source was playing, the resulting `pause` event
    /// echoes back and the coordinator's sink confirms broadcast.pause()
    /// (no-op since we started broadcast paused).
    func enforceInitialPause() {
        // Source might not yet be available (extension hasn't seen the
        // video element on the page yet). Send the command anyway —
        // the extension queues it and processes when ready. Worst case,
        // user has to manually pause once if the command was lost; in
        // practice the extension content script comes up within the
        // broadcast warmup window.
        print("[coordinator] enforcing initial paused state")
        source.pause()
    }

    // MARK: - State sync (the only place broadcast.isPaused changes)

    private func alignBroadcast(toSourcePlaying sourcePlaying: Bool) {
        guard let broadcast = broadcast else { return }
        // Don't touch broadcast until its engine is ready. Initial state
        // is set via broadcast.start(initialIsPaused:); subsequent
        // alignments happen when state events flow in.
        guard broadcast.engineSetupComplete else {
            print("[coordinator] state event arrived before engine ready; deferred")
            return
        }

        if sourcePlaying && broadcast.isPaused {
            print("[coordinator] source playing → broadcast resume")
            broadcast.resume()
            subtitles?.resumeRetirement()
        } else if !sourcePlaying && !broadcast.isPaused {
            print("[coordinator] source paused → broadcast pause")
            broadcast.pause()
            subtitles?.pauseRetirement()
        }
        // Already aligned — no-op.
    }
}
