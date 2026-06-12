import Foundation

/// Cross-cutting constants shared by multiple components.
enum BroadcastConstants {
    /// Sample rate fed into whisper.cpp. The model expects 16kHz mono.
    static let whisperSampleRate: Double = 16_000

    /// Fixed broadcast delay, in seconds. The capture/audio pipeline needs
    /// at least this long to warm up before frames are ready, so we don't
    /// expose it as a slider — going lower drops the first few seconds of
    /// playback; going higher just adds lag without a corresponding gain.
    static let defaultDelaySeconds: Double = 5.0

    /// Pump tick interval (~125Hz). Decoupled from capture FPS so audio scheduling stays smooth.
    static let pumpTickMilliseconds: Int = 8

    /// Subtitle main-glyph size range (point size). Furigana scales proportionally.
    static let subtitleFontSizeRange: ClosedRange<Double> = 18...56

    /// Subtitle persistence range (seconds). After this much active broadcast
    /// time on screen, an unreplaced phrase fades out so stale lines don't
    /// linger indefinitely. The clock pauses while playback is paused.
    static let subtitlePersistRange: ClosedRange<Double> = 1.0...20.0
    static let defaultSubtitlePersistSeconds: Double = 5.0

    /// Output-volume slider range. 0–1 maps directly to AVAudioMixerNode's
    /// linear outputVolume; 1–2 is realised as a globalGain boost on an
    /// AVAudioUnitEQ in series with the player (≈ +6 dB at 200%).
    static let volumeRange: ClosedRange<Float> = 0...2

    /// Throttle window for `togglePlayPause`. Drops auto-repeat key cascades
    /// (~30 Hz) without rejecting intentional rapid clicks.
    static let togglePlayPauseThrottle: TimeInterval = 0.15

    /// Fixed height of the playback-controls bar at the bottom of the
    /// broadcast window. Both the SwiftUI view and the window-sizing
    /// code reference this so the window grows to accommodate it
    /// instead of stealing pixels from the video region.
    static let broadcastPlaybackBarHeight: CGFloat = 44

    /// Height the subtitle area needs at a given main-glyph font size.
    /// Two stacked rows (main + ruby per row) plus inter-row spacing
    /// and vertical padding. Used by both the SwiftUI view (to size the
    /// area) and the window-sizing code (so the broadcast window grows
    /// when the font slider moves instead of squeezing the video).
    static func broadcastSubtitleAreaHeight(fontSize: Double) -> CGFloat {
        let main = fontSize * 1.2
        let ruby = fontSize * 0.42 * 1.2
        let rowH = main + 1 + ruby
        return rowH * 2 + 6 + 28
    }
}
