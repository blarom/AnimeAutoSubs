import Foundation

/// Cross-cutting constants shared by multiple components.
enum BroadcastConstants {
    /// Sample rate fed into whisper.cpp. The model expects 16kHz mono.
    static let whisperSampleRate: Double = 16_000

    /// Default and allowed range for the broadcast delay slider, in seconds.
    static let defaultDelaySeconds: Double = 5.0
    static let delaySecondsRange: ClosedRange<Double> = 3.0...8.0

    /// Pump tick interval (~125Hz). Decoupled from capture FPS so audio scheduling stays smooth.
    static let pumpTickMilliseconds: Int = 8

    /// Subtitle main-glyph size range (point size). Furigana scales proportionally.
    static let subtitleFontSizeRange: ClosedRange<Double> = 18...56

    /// Subtitle persistence range (seconds). After this much active broadcast
    /// time on screen, an unreplaced phrase fades out so stale lines don't
    /// linger indefinitely. The clock pauses while playback is paused.
    static let subtitlePersistRange: ClosedRange<Double> = 1.0...20.0
    static let defaultSubtitlePersistSeconds: Double = 3.0

    /// Output-volume slider range. 0–1 maps directly to AVAudioMixerNode's
    /// linear outputVolume; 1–2 is realised as a globalGain boost on an
    /// AVAudioUnitEQ in series with the player (≈ +6 dB at 200%).
    static let volumeRange: ClosedRange<Float> = 0...2

    /// Throttle window for `togglePlayPause`. Drops auto-repeat key cascades
    /// (~30 Hz) without rejecting intentional rapid clicks.
    static let togglePlayPauseThrottle: TimeInterval = 0.15
}
