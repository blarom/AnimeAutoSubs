import Foundation
import ScreenCaptureKit
import Combine

/// Enumerates browser windows via ScreenCaptureKit so the user can pick one to broadcast.
@MainActor
final class BrowserWindowEnumerator: ObservableObject {
    @Published var availableWindows: [SCWindow] = []

    private static let browserBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",      // Arc
        "company.thebrowser.dia",           // Dia
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    private static let minWindowSide: CGFloat = 200

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableWindows = content.windows.filter { window in
                guard let bundleID = window.owningApplication?.bundleIdentifier,
                      Self.browserBundles.contains(bundleID),
                      let title = window.title, !title.isEmpty,
                      window.isOnScreen,
                      window.frame.width > Self.minWindowSide,
                      window.frame.height > Self.minWindowSide else { return false }
                return true
            }
        } catch {
            print("[picker] failed to get shareable content: \(error)")
        }
    }
}
