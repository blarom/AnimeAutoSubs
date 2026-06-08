import Foundation
import AppKit
import CoreGraphics

/// Base class for the three session-level event taps the app uses
/// (`MediaKeyTap`, `CalibrationClickTap`, `PlayPauseTap`). Encapsulates the
/// `CGEvent.tapCreate` boilerplate, run-loop wiring, and the
/// `tapDisabledByTimeout` / `tapDisabledByUserInput` recovery branch — none
/// of which the subclasses need to think about.
///
/// Subclasses override `eventMask` (which `CGEventType`s to listen for),
/// `logPrefix` (for the install / uninstall log lines), and `handle(event:
/// type:)` (where the event-specific dispatch happens). Subclasses should
/// return `Unmanaged.passUnretained(event)` to pass through, `nil` to
/// consume.
class EventTap {
    /// Mask of CGEventTypes this tap listens for. Must be overridden.
    var eventMask: CGEventMask { 0 }

    /// Bracket-prefix used for tap-lifecycle log lines (`[<prefix>] tap
    /// installed`, etc.). Must be overridden.
    var logPrefix: String { "tap" }

    /// Whether the tap should consume events globally (`.defaultTap`) or
    /// just observe them (`.listenOnly`). Defaults to consume; the
    /// calibration click capture overrides to listen-only so the user's
    /// click reaches the source browser.
    var tapOptions: CGEventTapOptions { .defaultTap }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func install() {
        guard tap == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: tapOptions,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                // Auto-recovery — if the system has temporarily disabled the
                // tap (slow handler, user interaction), re-enable it and pass
                // the wakeup event through. Subclasses don't see these.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let p = me.tap { CGEvent.tapEnable(tap: p, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handle(event: event, type: type)
            },
            userInfo: selfPtr
        ) else {
            print("[\(logPrefix)] CGEvent.tapCreate failed (Accessibility may be missing)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = source
        print("[\(logPrefix)] event tap installed")
    }

    func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        tap = nil
        runLoopSource = nil
        print("[\(logPrefix)] event tap uninstalled")
    }

    /// Override to dispatch events. The base class has already filtered out
    /// `tapDisabled*` recovery events.
    func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        Unmanaged.passUnretained(event)
    }
}
