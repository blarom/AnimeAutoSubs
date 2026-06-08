import Foundation
import SafariServices
import Combine

/// Async wrapper around `SFSafariExtensionManager` for the AnimeAutoSubs
/// Safari Web Extension. Caches the most recent `isEnabled` state so the
/// dependency dashboard can show it red/green synchronously while a fresh
/// query runs in the background. Refreshed at app launch and whenever the
/// dashboard's Re-check button (or app-becomes-active) fires.
final class SafariExtensionStatusChecker: ObservableObject {
    static let shared = SafariExtensionStatusChecker()

    /// Bundle ID of the extension target. Must match what's in the Xcode
    /// project's Extension target Build Settings.
    private static let bundleID = "com.barlr.AnimeAutoSubs.Extension"

    /// Cached state — read synchronously by `DependencyCheck`.
    @Published private(set) var isEnabled: Bool = false
    /// True after at least one refresh has completed; lets us tell "extension
    /// is disabled" apart from "we haven't checked yet."
    @Published private(set) var hasChecked: Bool = false

    private init() {}

    /// Trigger an async refresh. Safe to call from any thread; mutations
    /// happen on the main queue.
    func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.bundleID) { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    print("[ext-check] SFSafariExtensionManager error: \(error)")
                }
                self.isEnabled = state?.isEnabled ?? false
                self.hasChecked = true
            }
        }
    }
}
