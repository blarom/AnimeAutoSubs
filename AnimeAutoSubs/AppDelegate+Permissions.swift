import AppKit
import ApplicationServices
import CoreGraphics

/// First-launch permission bootstrap. Silently checks Screen Recording +
/// Accessibility; if anything is missing, shows one consolidated alert that
/// can open the right TCC pane or fire the system prompts.
extension AppDelegate {

    /// Already-granted launches are completely silent. Anything missing triggers
    /// our explainer alert (and only then optionally the system prompts).
    func bootstrapPermissions() {
        var missing: [(name: String, settingsURL: String)] = []

        if !CGPreflightScreenCaptureAccess() {
            missing.append((
                name: "Screen Recording (to capture the browser window)",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ))
        }
        if !AXIsProcessTrusted() {
            missing.append((
                name: "Accessibility (to forward play/pause keystrokes)",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ))
        }

        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "AnimeAutoSubs needs additional permissions"
        let names = missing.map { "•  \($0.name)" }.joined(separator: "\n")
        alert.informativeText = "Grant the following, then quit and relaunch AnimeAutoSubs:\n\n\(names)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Anyway")
        let choice = alert.runModal()

        if choice == .alertFirstButtonReturn,
           let url = URL(string: missing[0].settingsURL) {
            NSWorkspace.shared.open(url)
            return
        }

        // User chose Continue — fire the system prompts as a fallback so they at
        // least get a chance to grant inline (Screen Recording) or be redirected
        // to Settings (Accessibility) before hitting the missing-permission paths.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        if !AXIsProcessTrusted() {
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let opts = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }
}
