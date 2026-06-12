import AppKit
import SwiftUI
import ScreenCaptureKit
import Combine

/// Window lifecycle + key-monitor + coordinate helper.
/// Properties stay on AppDelegate; methods live here.
extension AppDelegate {

    // MARK: - Layout constants

    private enum WindowLayout {
        static let picker = NSSize(width: 460, height: 520)
        static let dialog = NSSize(width: 320, height: 220)
        static let dashboard = NSSize(width: 580, height: 940)
        static let vocabulary = NSSize(width: 360, height: 600)
        static let screenEdgePadding: CGFloat = 24
        /// Slack around the source video rect when sizing the broadcast window:
        /// padding on all sides, plus a fixed allocation below for subtitles.
        static let broadcastChromeInset: CGFloat = 16
        static let broadcastSubtitleAllocation: CGFloat = 140
    }

    // MARK: - Picker

    @objc func showPickerWindow() {
        if let existing = pickerWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WindowPickerView(
            windowEnumerator: windowEnumerator,
            subtitleManager: subtitleManager,
            broadcastManager: broadcastManager,
            onStartBroadcast: { [weak self] window in
                self?.beginWizard(window: window)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayout.picker),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnimeAutoSubs"
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = WindowLayout.picker
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AnimeAutoSubs.Picker")
        var frame = window.frame
        let titleBarH = frame.height - window.contentLayoutRect.height
        let minFrameH = WindowLayout.picker.height + titleBarH
        if frame.size.width < WindowLayout.picker.width || frame.size.height < minFrameH {
            frame.size.width = max(frame.size.width, WindowLayout.picker.width)
            frame.size.height = max(frame.size.height, minFrameH)
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        pickerWindow = window
    }

    func beginWizard(window: SCWindow) {
        pickerWindow?.orderOut(nil)
        wizard.start(window: window)
    }

    // MARK: - Wizard overlays

    func handleStageChange(_ stage: BroadcastWizard.Stage) {
        switch stage {
        case .idle:
            teardownWizardOverlays()
        case .fine:
            ensureDialogWindow()
            ensureFineOverlayWindow()
        case .broadcasting:
            greenOverlayWindow?.orderOut(nil)
            greenOverlayWindow = nil
            // Dialog stays — content updates
        }
    }

    func teardownWizardOverlays() {
        greenOverlayWindow?.orderOut(nil)
        greenOverlayWindow = nil
        dialogWindow?.orderOut(nil)
        dialogWindow = nil
    }

    private func ensureFineOverlayWindow() {
        guard let win = wizard.sourceWindow, greenOverlayWindow == nil else { return }
        let nsFrame = ccgToNSScreen(scFrame: win.frame)
        let overlayWin = makeOpaqueOverlayWindow(at: nsFrame)
        let hostView = NSHostingView(
            rootView: SnapshotRectContainer(wizard: wizard, color: .green, dashed: false)
        )
        hostView.frame = NSRect(origin: .zero, size: nsFrame.size)
        hostView.autoresizingMask = [.width, .height]
        overlayWin.contentView = hostView
        overlayWin.makeKeyAndOrderFront(nil)
        greenOverlayWindow = overlayWin
    }

    func ensureDialogWindow() {
        if let existing = dialogWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WizardDialogView(
            wizard: wizard,
            broadcastManager: broadcastManager,
            subtitleManager: subtitleManager,
            mediaSource: mediaSource,
            onStop: { [weak self] in self?.stopBroadcast() }
        )
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayout.dialog),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "AnimeAutoSubs"
        // .popUpMenu (101) is the highest standard NSWindow level. Keeps
        // the dialog visible above the green selection overlay (.floating)
        // and across space changes (with the collection-behavior flags).
        win.level = .popUpMenu
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            win.setFrameOrigin(NSPoint(
                x: v.maxX - 360,
                y: v.maxY - 260
            ))
        }
        win.setFrameAutosaveName("AnimeAutoSubs.Dialog")
        // If the autosave loaded a frame entirely off-screen, snap back
        // to the default top-right position.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(win.frame) }) {
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                win.setFrameOrigin(NSPoint(x: v.maxX - 360, y: v.maxY - 260))
            }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dialogWindow = win
    }

    // MARK: - Broadcast

    func startBroadcast(window: SCWindow, sourceRect: CGRect, initialIsPaused: Bool = false) {
        if broadcastWindow != nil { stopBroadcast() }

        // Pick the bridge that matches the selected browser window and
        // hand it to the router. Everything downstream — coordinator,
        // dialog UI, broadcast bar — reads through the router so it
        // doesn't care which concrete transport is active.
        let bridge = selectBridge(forWindow: window)
        mediaSource.setActive(bridge)

        let view = BroadcastPlayerView(
            manager: broadcastManager,
            subtitleManager: subtitleManager,
            mediaSource: mediaSource,
            onPlayPause: { [weak self] in self?.togglePlayPause() },
            onSkip: { [weak self] delta in self?.skipSource(by: delta) },
            onSeek: { [weak self] time in self?.seekSource(to: time) },
            onClose: { [weak self] in self?.stopBroadcast() }
        )

        let scScreenRect = window.frame
        let absRect = CGRect(
            x: scScreenRect.origin.x + sourceRect.origin.x,
            y: scScreenRect.origin.y + sourceRect.origin.y,
            width: sourceRect.width,
            height: sourceRect.height
        )
        let nsRect = ccgToNSScreen(scFrame: absRect)
        broadcastVideoRect = nsRect
        let chrome = WindowLayout.broadcastChromeInset
        let subtitleH = BroadcastConstants.broadcastSubtitleAreaHeight(fontSize: broadcastManager.subtitleFontSize)
        let playbackH = BroadcastConstants.broadcastPlaybackBarHeight
        let extras = subtitleH + playbackH
        let winFrame = NSRect(
            x: nsRect.origin.x - chrome,
            y: nsRect.origin.y - extras - chrome,
            width: nsRect.width + chrome * 2,
            height: nsRect.height + extras + chrome * 2
        )

        let win = BroadcastWindow(
            contentRect: winFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: winFrame.size)
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        broadcastWindow = win

        // Resize the window when the subtitle font slider moves so the
        // video region keeps its captured size (the slider changes the
        // subtitle area's needed height; the window grows around it).
        // No `.receive(on: RunLoop.main)` — that queues the resize for
        // the next runloop tick, which causes the video region to
        // visibly shrink during the drag while the window catches up
        // only on release. Synchronous resize preempts SwiftUI's render
        // pass for the same tick so the video stays put throughout.
        broadcastManager.$subtitleFontSize
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resizeBroadcastWindowForLayoutChange() }
            .store(in: &cancellables)

        installBroadcastSpacebarMonitor()
        installMediaKeyTap()

        Task {
            do {
                try await broadcastManager.start(window: window, sourceRect: sourceRect, initialIsPaused: initialIsPaused)
            } catch {
                print("[broadcast] failed to start: \(error)")
                await MainActor.run { self.stopBroadcast() }
            }
        }
        showVocabularyWindow()
    }

    func stopBroadcast() {
        removeBroadcastSpacebarMonitor()
        mediaKeyTap.uninstall()
        Task { await broadcastManager.stop() }
        broadcastWindow?.orderOut(nil)
        broadcastWindow = nil
        broadcastVideoRect = nil
        mediaSource.setActive(nil)
        wizard.abort()
        showPickerWindow()
    }

    /// Decide which concrete `VideoControlSource` should be active for
    /// a broadcast session, based on the selected window's owning app
    /// and (for Safari) the user's transport preference. Lives here so
    /// the routing rules are in one place — keep this exhaustive as new
    /// browser bridges are added.
    private func selectBridge(forWindow window: SCWindow) -> VideoControlSource {
        let appName = window.owningApplication?.applicationName ?? "?"
        let lower = appName.lowercased()

        // Safari (and Safari Technology Preview): pick the transport
        // the user has configured. Default is file IPC during the
        // verification window for the new HTTP path.
        if lower.contains("safari") {
            let mode = UserDefaults.standard.string(forKey: "safariTransport") ?? "file"
            if mode == "http" {
                print("[bridge-select] window owner=\(appName) → HTTPExtensionBridge(Safari)")
                return safariHTTPBridge
            }
            print("[bridge-select] window owner=\(appName) → ExtensionBridge (Safari file IPC)")
            return extensionBridge
        }

        // Chromium-based browsers all use the same extension API surface
        // and the same HTTP bridge from our side. The Chrome extension
        // gets sideloaded in dev mode for now.
        let chromiumNames = ["chrome", "chromium", "brave", "edge", "arc", "vivaldi", "opera"]
        if chromiumNames.contains(where: { lower.contains($0) }) {
            print("[bridge-select] window owner=\(appName) → HTTPExtensionBridge(Chrome)")
            return chromeHTTPBridge
        }

        // Unknown browser. Default to Chrome HTTP since most modern
        // browsers are Chromium-derivatives; the user will see a "no
        // video reachable" tip if the extension isn't installed.
        print("[bridge-select] window owner=\(appName) is unknown — defaulting to HTTPExtensionBridge(Chrome)")
        return chromeHTTPBridge
    }

    /// Recompute the broadcast window's frame so the video region stays at
    /// its captured size while the surrounding bars (subtitle area,
    /// playback bar) absorb their currently-needed heights. Called when
    /// `subtitleFontSize` changes; the top-left of the window is held
    /// fixed so the window doesn't jump up the screen.
    func resizeBroadcastWindowForLayoutChange() {
        guard let win = broadcastWindow,
              let videoRect = broadcastVideoRect else { return }
        let chrome = WindowLayout.broadcastChromeInset
        let subtitleH = BroadcastConstants.broadcastSubtitleAreaHeight(fontSize: broadcastManager.subtitleFontSize)
        let playbackH = BroadcastConstants.broadcastPlaybackBarHeight
        let extras = subtitleH + playbackH
        let newHeight = videoRect.height + extras + chrome * 2
        let newWidth = videoRect.width + chrome * 2
        let current = win.frame
        let topY = current.origin.y + current.height
        let newFrame = NSRect(
            x: current.origin.x,
            y: topY - newHeight,
            width: newWidth,
            height: newHeight
        )
        if abs(newFrame.size.height - current.size.height) < 0.5 { return }
        win.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Broadcast-window keystroke monitor

    /// Catch broadcast-window keystrokes at the app level. Currently only
    /// the `S` blur-subtitles toggle. Spacebar play/pause is delegated to
    /// the Safari Web Extension via `ExtensionBridge`, so we don't need a
    /// global key tap to intercept it.
    func installBroadcastSpacebarMonitor() {
        removeBroadcastSpacebarMonitor()
        broadcastKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self,
                  NSApp.keyWindow === self.broadcastWindow else {
                return event
            }
            if event.isARepeat { return nil }
            switch event.keyCode {
            case 0x01:  // S
                self.broadcastManager.blurEnglishSubtitles.toggle()
                return nil
            default:
                return event
            }
        }
    }

    func removeBroadcastSpacebarMonitor() {
        if let monitor = broadcastKeyMonitor {
            NSEvent.removeMonitor(monitor)
            broadcastKeyMonitor = nil
        }
    }

    // MARK: - Media-key tap (global volume keys)

    /// Install the global event tap and route the three media-key callbacks
    /// to the broadcast device's *hardware* volume — not the engine's
    /// software gain. During a broadcast the system default is BlackHole
    /// (silent), so without this the keys would silently change a device
    /// the user can't hear.
    private func installMediaKeyTap() {
        mediaKeyTap.onVolumeUp = { [weak self] in
            self?.nudgeBroadcastDeviceVolume(by: +1.0/16.0)
        }
        mediaKeyTap.onVolumeDown = { [weak self] in
            self?.nudgeBroadcastDeviceVolume(by: -1.0/16.0)
        }
        mediaKeyTap.onMute = { [weak self] in
            self?.muteBroadcastDevice()
        }
        mediaKeyTap.install()
    }

    private func nudgeBroadcastDeviceVolume(by delta: Float) {
        guard let deviceID = broadcastManager.currentBroadcastOutputDeviceID else {
            print("[mediakeys] no currentBroadcastOutputDeviceID; nudge dropped")
            return
        }
        let current = AudioDeviceManager.shared.outputVolume(of: deviceID) ?? 0.5
        let next = max(0, min(1, current + delta))
        let ok = AudioDeviceManager.shared.setOutputVolume(next, of: deviceID)
        print("[mediakeys] device=\(deviceID) volume \(current) → \(next) ok=\(ok)")
    }

    private func muteBroadcastDevice() {
        guard let deviceID = broadcastManager.currentBroadcastOutputDeviceID else { return }
        _ = AudioDeviceManager.shared.setOutputVolume(0, of: deviceID)
    }

    // MARK: - Vocabulary window

    @objc func showVocabularyWindow() {
        if let existing = vocabularyWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = VocabularyView(manager: vocabularyManager)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayout.vocabulary),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Vocabulary"
        win.contentView = NSHostingView(rootView: view)
        win.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let pad = WindowLayout.screenEdgePadding
            win.setFrameOrigin(NSPoint(
                x: v.maxX - pad - win.frame.width,
                y: v.maxY - pad - win.frame.height
            ))
        }
        win.setFrameAutosaveName("AnimeAutoSubs.Vocabulary")
        win.orderFront(nil)
        vocabularyWindow = win
    }

    // MARK: - Dependency dashboard

    @objc func showDependencyDashboard() {
        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DependencyDashboardView(
            statuses: DependencyCheck.statuses(),
            onRecheck: { DependencyCheck.statuses() },
            onClose: { [weak self] in
                self?.dashboardWindow?.orderOut(nil)
            }
        )
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayout.dashboard),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "AnimeAutoSubs setup"
        win.contentView = NSHostingView(rootView: view)
        win.contentMinSize = WindowLayout.dashboard
        win.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let pad = WindowLayout.screenEdgePadding
            win.setFrameOrigin(NSPoint(
                x: v.minX + pad,
                y: v.maxY - pad - win.frame.height
            ))
        }
        win.setFrameAutosaveName("AnimeAutoSubs.Dashboard")
        var frame = win.frame
        let titleBarH = frame.height - win.contentLayoutRect.height
        let minFrameH = WindowLayout.dashboard.height + titleBarH
        if frame.size.width < WindowLayout.dashboard.width || frame.size.height < minFrameH {
            frame.size.width = max(frame.size.width, WindowLayout.dashboard.width)
            frame.size.height = max(frame.size.height, minFrameH)
            win.setFrame(frame, display: false)
        }
        win.orderFront(nil)
        dashboardWindow = win
    }

    // MARK: - Helpers

    /// SCWindow.frame uses CG screen coords (top-left origin on primary display).
    /// NSWindow uses Cocoa coords (bottom-left origin on primary display).
    func ccgToNSScreen(scFrame: CGRect) -> NSRect {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let primaryHeight = screen?.frame.height ?? 0
        return NSRect(
            x: scFrame.origin.x,
            y: primaryHeight - scFrame.origin.y - scFrame.height,
            width: scFrame.width,
            height: scFrame.height
        )
    }

    private func makeOpaqueOverlayWindow(at nsFrame: NSRect) -> NSWindow {
        let win = NSWindow(
            contentRect: nsFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return win
    }
}
