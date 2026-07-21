import AppKit
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controllers: [String: Any] = [:]      // uuid -> FlipController
    // One flipped output at a time: every workspace competes for the same arrangement
    // slot beside the anchor display. A set is kept only for compatibility with the
    // v0.3 UserDefaults format; reconcile collapses legacy multi-selections.
    private var selected: Set<String> = []            // uuid of the display to flip
    private let defaultsKey = "flippedDisplayUUIDs"
    private let cursorFlipKey = "flipCursor"
    private var savedArrangement: [String: CGPoint] = [:]    // display uuid -> origin
    private var pendingScreensChange: DispatchWorkItem?
    private var requestedScreenRecordingThisLaunch = false

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.reset()
        Log.line("=== ScreenFlip launched (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
        NSApp.setActivationPolicy(.accessory)

        // Remember the user's display layout so we can restore it on quit (we relocate
        // displays to host the virtual workspace).
        savedArrangement = Displays.snapshotOrigins()

        selected = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        Log.line("restored selection: \(selected)")
        for d in Displays.all() {
            Log.line("display \(d.id): \"\(d.label)\" uuid=\(d.uuid)\(d.isWorkspace ? " [workspace]" : "")")
        }

        setupStatusItem()

        // Only ask for Screen Recording when there's a remembered output to resume —
        // prompting merely because a menu-bar app launched reads as a surprise. A fresh
        // selection triggers the prompt from toggleDisplay instead.
        if !selected.isEmpty {
            primeScreenRecordingPermission()
        }

        // React to display hotplug / rearrangement.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        reconcile()
        MirrorInput.shared.setCursorFlipped(UserDefaults.standard.bool(forKey: cursorFlipKey))
        rebuildMenu()
    }

    // MARK: Permission priming
    private func primeScreenRecordingPermission() {
        let granted = CGPreflightScreenCaptureAccess()
        Log.line("CGPreflightScreenCaptureAccess = \(granted)")
        guard !granted, !requestedScreenRecordingThisLaunch else { return }
        requestedScreenRecordingThisLaunch = true

        DispatchQueue.global(qos: .userInitiated).async {
            let allowed = CGRequestScreenCaptureAccess()
            Log.line("CGRequestScreenCaptureAccess = \(allowed)")
            DispatchQueue.main.async {
                self.reconcile()
                self.rebuildMenu()
            }
        }
    }

    // MARK: Selection / reconcile
    /// Ensure a running FlipController exists for every selected+active display, and
    /// none for the rest. Called on launch, on toggle, and on display changes.
    private var reconciling = false
    private func reconcile() {
        guard #available(macOS 13.0, *) else { return }
        guard !reconciling else { return }     // creating/repositioning the virtual display
        reconciling = true                      // fires didChangeScreenParameters; avoid re-entry
        defer { reconciling = false }

        guard CGPreflightScreenCaptureAccess() else {
            if !controllers.isEmpty {
                for (_, ctrl) in controllers { (ctrl as? FlipController)?.stop() }
                controllers.removeAll()
            }
            MirrorInput.shared.setMappings([])
            Log.line("reconcile deferred: Screen Recording permission is not available")
            return
        }

        let active = Displays.eligibleOutputs()
        let activeByUUID = Dictionary(uniqueKeysWithValues: active.map { ($0.uuid, $0) })

        // v0.3 allowed multiple selections even though every controller competed for
        // the same arrangement slot. Collapse an old preference deterministically.
        let activeSelections = active.filter { selected.contains($0.uuid) }
        if activeSelections.count > 1, let keep = activeSelections.first {
            selected = [keep.uuid]
            persistSelection()
            Log.line("migrated multiple selections; keeping \(keep.uuid)")
        }

        // Stop controllers that are no longer selected, whose physical display vanished,
        // whose virtual workspace died (system terminated it / creation failed), or whose
        // output changed size (reconnect at a different resolution) — the last two groups
        // get recreated below with a fresh workspace.
        for (uuid, ctrl) in controllers {
            let fc = ctrl as? FlipController
            let keep = selected.contains(uuid) && activeByUUID[uuid] != nil
                    && fc?.workspaceAlive == true && fc?.needsRebuild != true
            guard !keep else { continue }
            fc?.stop()
            controllers[uuid] = nil
        }
        // Start controllers for selected, active displays not yet running.
        for uuid in selected {
            guard controllers[uuid] == nil, let info = activeByUUID[uuid] else { continue }
            if let ctrl = FlipController(display: info, axis: .horizontal) {
                ctrl.onNeedsReconcile = { [weak self] in self?.reconcile() }
                ctrl.start()
                controllers[uuid] = ctrl
            }
        }
        Log.line("reconcile: \(controllers.count) workspace(s) of \(selected.count) selected, \(active.count) active")

        // The cursor proxy is intrinsic to the virtual workspace: the headless display has
        // no visible system cursor, so MirrorInput draws one on the flipped output. It also
        // guards the output display's edges — the cursor is pinned to the workspace rather
        // than allowed onto the output panel. Other screens are untouched.
        let maps = controllers.values.compactMap { ($0 as? FlipController)?.mapping }
        MirrorInput.shared.setMappings(maps)
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        if selected.contains(uuid) {
            selected.removeAll()
        } else {
            selected = [uuid]        // single output — selecting one deselects the rest
        }
        persistSelection()
        if !selected.isEmpty {
            // Ask in direct response to the user's choice instead of surprising them
            // with a privacy prompt merely because the menu-bar app launched.
            primeScreenRecordingPermission()
        }
        reconcile()
        rebuildMenu()
    }

    private func persistSelection() {
        UserDefaults.standard.set(Array(selected), forKey: defaultsKey)
    }

    @objc private func screensChanged() {
        guard !reconciling else { return }
        Log.line("display configuration changed")
        // Overlays track their output immediately so a rearrangement never leaves a
        // flipped picture parked over the wrong display…
        if #available(macOS 13.0, *) {
            for ctrl in controllers.values { (ctrl as? FlipController)?.repositionOverlay() }
        }
        // …but reconcile only after the burst settles: one hotplug fires several of
        // these notifications, and rebuilding workspaces against half-settled bounds
        // is how duplicate workspaces and wrong-display flips happened mid-session.
        pendingScreensChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if #available(macOS 13.0, *) {
                for ctrl in self.controllers.values { (ctrl as? FlipController)?.repositionOverlay() }
            }
            self.reconcile()
            self.rebuildMenu()
        }
        pendingScreensChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Menu
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇋"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Flip one external display:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for d in Displays.physical() {
            let suffix = d.isMain ? " (not available)" : ""
            let item = NSMenuItem(title: d.label + suffix,
                                  action: d.isMain ? nil : #selector(toggleDisplay(_:)),
                                  keyEquivalent: "")
            if d.isMain {
                item.isEnabled = false
            } else {
                item.representedObject = d.uuid
                item.state = selected.contains(d.uuid) ? .on : .off
                item.target = self
            }
            menu.addItem(item)
        }

        if Displays.eligibleOutputs().isEmpty {
            let empty = NSMenuItem(title: "Connect a second display to begin", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let noteTitle = controllers.isEmpty ? "Inactive" : "Active — the flipped display mirrors its hidden workspace"
        let note = NSMenuItem(title: noteTitle, action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)

        let flipCursorItem = NSMenuItem(title: "Flip cursor to match mirror",
                                        action: #selector(toggleCursorFlip), keyEquivalent: "")
        flipCursorItem.state = UserDefaults.standard.bool(forKey: cursorFlipKey) ? .on : .off
        flipCursorItem.target = self
        menu.addItem(flipCursorItem)

        menu.addItem(.separator())
        if !CGPreflightScreenCaptureAccess() {
            let warn = NSMenuItem(title: "⚠︎ Grant Screen Recording…", action: #selector(openScreenRecordingPrefs), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        let restart = NSMenuItem(title: "Restart all", action: #selector(restartAll), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "Quit ScreenFlip", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleCursorFlip() {
        let on = !UserDefaults.standard.bool(forKey: cursorFlipKey)
        UserDefaults.standard.set(on, forKey: cursorFlipKey)
        MirrorInput.shared.setCursorFlipped(on)
        rebuildMenu()
    }

    @objc private func openScreenRecordingPrefs() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func restartAll() {
        guard #available(macOS 13.0, *) else { return }
        for (_, ctrl) in controllers { (ctrl as? FlipController)?.stop() }
        controllers.removeAll()
        reconcile()
    }

    @objc private func quit() {
        if #available(macOS 13.0, *) {
            for (_, ctrl) in controllers { (ctrl as? FlipController)?.stop() }
        }
        MirrorInput.shared.setMappings([])
        Displays.restoreOrigins(savedArrangement)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        Displays.restoreOrigins(savedArrangement)
    }
}
