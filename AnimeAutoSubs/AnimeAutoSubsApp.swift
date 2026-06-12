import SwiftUI
import ScreenCaptureKit
import Combine
import AppKit

@main
struct AnimeAutoSubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Borderless windows default to canBecomeKey == false, which means clicking
/// the broadcast window doesn't actually make it the key window — so any
/// in-window keyboard shortcut would be routed elsewhere. Overriding
/// canBecomeKey lets our broadcast window receive keystrokes when focused.
final class BroadcastWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Windows
    var pickerWindow: NSWindow?
    var broadcastWindow: NSWindow?
    var greenOverlayWindow: NSWindow?
    var dialogWindow: NSWindow?
    var dashboardWindow: NSWindow?
    var vocabularyWindow: NSWindow?

    /// Video region (in screen coordinates) of the currently active
    /// broadcast — kept around so the broadcast window can be resized
    /// when the subtitle font size changes, without affecting the video
    /// area's size or position.
    var broadcastVideoRect: NSRect?

    // Status menu
    var statusItem: NSStatusItem?
    var primaryMenuItem: NSMenuItem?
    var dashboardMenuItem: NSMenuItem?
    var vocabularyMenuItem: NSMenuItem?
    var outputDeviceSubmenu: NSMenu?
    let outputDeviceUIDKey = "preferredOutputDeviceUID"

    /// Local NSEvent monitor for keystrokes when the broadcast window is
    /// key — `S` for English-blur toggle. Spacebar is intentionally not
    /// handled: the play/pause control flows uniformly through the
    /// `PlayPauseCoordinator` and the dialog's Play/Pause button (or
    /// the Safari extension popup) is the canonical input.
    var broadcastKeyMonitor: Any?

    /// Global event tap that intercepts the system media keys (volume up,
    /// volume down, mute) so they adjust the broadcast device's hardware
    /// volume — not the system default, which is BlackHole during broadcast.
    let mediaKeyTap = MediaKeyTap()

    // Managers
    let windowEnumerator = BrowserWindowEnumerator()
    let subtitleManager = SubtitleManager()
    let broadcastManager = BroadcastDelayManager()
    let wizard = BroadcastWizard()
    let vocabularyManager = VocabularyManager()

    /// Bridge to the Safari Web Extension. Conforms to `VideoControlSource`,
    /// so the coordinator (and any future browser bridges) talks to it via
    /// that abstraction.
    let extensionBridge = ExtensionBridge()

    /// The single play/pause brain. Mirrors source state to broadcast,
    /// enforces initial pause at broadcast start, owns the only place
    /// `broadcastManager.isPaused` flips for non-stop transitions.
    lazy var playPauseCoordinator: PlayPauseCoordinator = PlayPauseCoordinator(
        source: extensionBridge,
        broadcast: broadcastManager,
        subtitles: subtitleManager
    )

    var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Recovery: if a previous run crashed while routing to BlackHole, restore.
        if let currentID = AudioDeviceManager.shared.currentDefaultOutputDevice(),
           let dev = AudioDeviceManager.shared.listOutputDevices().first(where: { $0.id == currentID }),
           dev.isBlackHole {
            broadcastManager.restoreSavedOutputDevice()
        }
        // Touch the coordinator so its lazy init runs and it subscribes
        // to the bridge's state publisher before any broadcast starts.
        _ = playPauseCoordinator
        setupMenuBar()
        wireWizard()
        wireVocabulary()
        loadPreferredOutputDevice()
        SafariExtensionStatusChecker.shared.refresh()
        bootstrapPermissions()
        showDependencyDashboard()
        showPickerWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        broadcastManager.restoreSavedOutputDevice()
        WhisperServer.shared.stop()
    }

    // MARK: - Wiring

    private func wireVocabulary() {
        subtitleManager.onPhraseDisplayed = { [weak self] tokens in
            self?.vocabularyManager.record(tokens)
        }
    }

    private func wireWizard() {
        wizard.onConfirmFine = { [weak self] window, fineRect in
            // Broadcast always starts paused. The coordinator commands
            // the source to pause shortly after; if source was playing,
            // the resulting pause event syncs broadcast (no-op since
            // broadcast already paused). If source was already paused,
            // both are aligned. User clicks Play to begin watching.
            self?.startBroadcast(window: window, sourceRect: fineRect, initialIsPaused: true)
            self?.playPauseCoordinator.enforceInitialPause()
        }
        wizard.onCancel = { [weak self] in
            self?.teardownWizardOverlays()
            self?.showPickerWindow()
        }
        wizard.onAbort = { [weak self] in
            self?.teardownWizardOverlays()
        }
        wizard.$stage
            .receive(on: RunLoop.main)
            .sink { [weak self] stage in
                self?.handleStageChange(stage)
                self?.updatePrimaryMenuItem()
            }
            .store(in: &cancellables)
    }

    // MARK: - Play/Pause

    /// Single user-input entry point. Wired to the dialog's Play/Pause
    /// button (and any future input). Delegates to the coordinator,
    /// which commands the source. Broadcast follows when the state
    /// echo arrives ~250 ms later.
    func togglePlayPause() {
        playPauseCoordinator.userToggle()
    }

    /// Skip the source ±N seconds. Wired to the broadcast window's
    /// playback bar buttons.
    func skipSource(by delta: Double) {
        playPauseCoordinator.userSkip(by: delta)
    }

    /// Jump the source to an absolute media time. Wired to the broadcast
    /// window's scrub slider on release.
    func seekSource(to time: Double) {
        playPauseCoordinator.userSeek(to: time)
    }
}
