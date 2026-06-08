import Foundation
import AppKit
import CoreGraphics

/// Global tap that intercepts the system-defined media-key events (volume up,
/// volume down, mute) and forwards them to local handlers — even when our app
/// is not the foreground app. `NSEvent.addLocalMonitorForEvents` only fires
/// when our app is key, which is the wrong behavior for a broadcast tool: the
/// user is usually focused on the browser they're capturing, so without this
/// tap the keys would just adjust the system default output (BlackHole during
/// a broadcast) and never reach our handlers.
///
/// Requires Accessibility permission. We already require it for posting the
/// play/pause click to the source app, so no new TCC dependency.
final class MediaKeyTap: EventTap {
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMute: (() -> Void)?

    /// CGEventType has no Swift case for systemDefined (raw value 14), so
    /// the mask is built from the raw value directly.
    override var eventMask: CGEventMask { CGEventMask(1 << 14) }
    override var logPrefix: String { "mediakeys" }

    override func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Match systemDefined (raw 14) and subtype 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS.
        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else {
            return Unmanaged.passUnretained(event)
        }
        let raw = nsEvent.data1
        let keyCode = (raw & 0xFFFF0000) >> 16
        let isKeyDown = ((raw & 0x0000FF00) >> 8) == 0xA
        guard isKeyDown else {
            // Consume the matching key-up too so the system volume controller
            // doesn't act on it asymmetrically.
            return nil
        }
        switch keyCode {
        case 0:  // NX_KEYTYPE_SOUND_UP
            DispatchQueue.main.async { self.onVolumeUp?() }
            return nil
        case 1:  // NX_KEYTYPE_SOUND_DOWN
            DispatchQueue.main.async { self.onVolumeDown?() }
            return nil
        case 7:  // NX_KEYTYPE_MUTE
            DispatchQueue.main.async { self.onMute?() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
