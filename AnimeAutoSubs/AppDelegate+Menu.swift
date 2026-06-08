import AppKit
import CoreAudio

/// Status-bar menu setup, audio-output submenu management, and the persisted
/// preferred output device. Lives on AppDelegate as an extension to keep the
/// core file focused on lifecycle and broadcast flow.
extension AppDelegate: NSMenuDelegate {

    // MARK: - Status menu

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "字"
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "AnimeAutoSubs")
            button.imagePosition = .imageLeft
        }

        let menu = NSMenu()
        menu.delegate = self  // refresh toggle labels just-in-time

        let primary = NSMenuItem(title: "Show Picker", action: #selector(togglePrimaryWindow), keyEquivalent: "p")
        menu.addItem(primary)
        primaryMenuItem = primary

        menu.addItem(NSMenuItem(title: "Stop Broadcast", action: #selector(menuStopBroadcast), keyEquivalent: ""))

        let vocab = NSMenuItem(title: "Show Vocabulary", action: #selector(toggleVocabularyWindow), keyEquivalent: "")
        menu.addItem(vocab)
        vocabularyMenuItem = vocab

        let dashboard = NSMenuItem(title: "Show Setup Dashboard", action: #selector(toggleDependencyDashboard), keyEquivalent: "")
        menu.addItem(dashboard)
        dashboardMenuItem = dashboard

        menu.addItem(NSMenuItem.separator())

        let outputDeviceParent = NSMenuItem(title: "Audio Output (delayed)", action: nil, keyEquivalent: "")
        let outputDeviceMenu = NSMenu()
        outputDeviceParent.submenu = outputDeviceMenu
        menu.addItem(outputDeviceParent)
        outputDeviceSubmenu = outputDeviceMenu
        rebuildOutputDeviceSubmenu()

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu

        refreshAllToggleMenuItems()
    }

    // MARK: - NSMenuDelegate

    /// Called right before the user sees the menu — perfect spot to sync the
    /// "Show / Hide ..." labels with the actual visibility of each window.
    /// Avoids us needing to listen for NSWindow open/close notifications.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAllToggleMenuItems()
    }

    // MARK: - Toggle methods

    /// Picker (idle) or Broadcast Control (broadcasting), whichever applies.
    @objc func togglePrimaryWindow() {
        if wizard.stage != .idle {
            if let dialog = dialogWindow, dialog.isVisible {
                dialog.orderOut(nil)
            } else {
                ensureDialogWindow()
                dialogWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            if let picker = pickerWindow, picker.isVisible {
                picker.orderOut(nil)
            } else {
                showPickerWindow()
            }
        }
        refreshAllToggleMenuItems()
    }

    @objc func toggleVocabularyWindow() {
        if let win = vocabularyWindow, win.isVisible {
            win.orderOut(nil)
        } else {
            showVocabularyWindow()
        }
        refreshAllToggleMenuItems()
    }

    @objc func toggleDependencyDashboard() {
        if let win = dashboardWindow, win.isVisible {
            win.orderOut(nil)
        } else {
            showDependencyDashboard()
        }
        refreshAllToggleMenuItems()
    }

    @objc func menuStopBroadcast() { stopBroadcast() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Label refresh

    /// Sync each toggle menu item's label with its window's actual visibility.
    func refreshAllToggleMenuItems() {
        updatePrimaryMenuItem()
        if let item = vocabularyMenuItem {
            let visible = vocabularyWindow?.isVisible ?? false
            item.title = visible ? "Hide Vocabulary" : "Show Vocabulary"
        }
        if let item = dashboardMenuItem {
            let visible = dashboardWindow?.isVisible ?? false
            item.title = visible ? "Hide Setup Dashboard" : "Show Setup Dashboard"
        }
    }

    /// Toggle label tracks the current foreground task (broadcast vs idle) and
    /// whether the corresponding window is already visible.
    func updatePrimaryMenuItem() {
        guard let item = primaryMenuItem else { return }
        let isBroadcasting = wizard.stage != .idle
        if isBroadcasting {
            let visible = dialogWindow?.isVisible ?? false
            item.title = visible ? "Hide Broadcast Control" : "Show Broadcast Control"
        } else {
            let visible = pickerWindow?.isVisible ?? false
            item.title = visible ? "Hide Picker" : "Show Picker"
        }
    }

    // MARK: - Audio output submenu

    func loadPreferredOutputDevice() {
        let uid = UserDefaults.standard.string(forKey: outputDeviceUIDKey)
        if let uid, let device = AudioDeviceManager.shared.device(matching: uid) {
            broadcastManager.preferredOutputDeviceID = device.id
            return
        }
        // Default: pick the current system default output if it's not BlackHole.
        guard let currentID = AudioDeviceManager.shared.currentDefaultOutputDevice() else { return }
        let devices = AudioDeviceManager.shared.listOutputDevices()
        if let dev = devices.first(where: { $0.id == currentID }), !dev.isBlackHole {
            broadcastManager.preferredOutputDeviceID = dev.id
            UserDefaults.standard.set(dev.uid, forKey: outputDeviceUIDKey)
        }
    }

    func rebuildOutputDeviceSubmenu() {
        guard let submenu = outputDeviceSubmenu else { return }
        submenu.removeAllItems()
        let devices = AudioDeviceManager.shared.listOutputDevices().filter { !$0.isBlackHole }
        if devices.isEmpty {
            submenu.addItem(NSMenuItem(title: "No output devices", action: nil, keyEquivalent: ""))
            return
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectOutputDevice(_:)), keyEquivalent: "")
            item.representedObject = device.uid
            item.target = self
            if device.id == broadcastManager.preferredOutputDeviceID {
                item.state = .on
            }
            submenu.addItem(item)
        }
        submenu.addItem(NSMenuItem.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshOutputDevices), keyEquivalent: "")
        refresh.target = self
        submenu.addItem(refresh)
    }

    @objc func selectOutputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let device = AudioDeviceManager.shared.device(matching: uid) else { return }
        broadcastManager.preferredOutputDeviceID = device.id
        UserDefaults.standard.set(device.uid, forKey: outputDeviceUIDKey)
        rebuildOutputDeviceSubmenu()
    }

    @objc func refreshOutputDevices() {
        rebuildOutputDeviceSubmenu()
    }
}
