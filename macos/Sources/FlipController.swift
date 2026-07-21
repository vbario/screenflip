import AppKit
import ScreenCaptureKit

/// Ties a physical output display to its hidden virtual workspace, for the cursor
/// proxy. Geometry is deliberately NOT cached here — display bounds go stale the
/// moment the OS adjusts the arrangement (hotplug, resolution change, overlap
/// resolution), so consumers must look rects up live by display ID.
struct WorkspaceMapping {
    let pDisplayID: CGDirectDisplayID     // physical output (where the user looks)
    let vDisplayID: CGDirectDisplayID     // hidden virtual workspace
}

/// Owns one "virtual flipped workspace":
///  • a headless virtual display V — placed in the arrangement as a NORMAL extended
///    display immediately to the RIGHT of the anchor screen, so the cursor flows onto
///    it natively (no input interception);
///  • the chosen PHYSICAL output P — moved just past V and covered with a full-screen
///    overlay that shows V captured + horizontally flipped.
/// The user looks at P and sees the workspace mirrored; the cursor lives natively on V.
@available(macOS 13.0, *)
final class FlipController {
    let displayID: CGDirectDisplayID      // physical output (P)
    let uuid: String
    private var overlay: OverlayWindow
    private let capture = Capture()
    private let axis: FlipAxis
    private var virtual: VirtualDisplay?
    private var createdOutputSize: CGSize = .zero
    var onNeedsReconcile: (() -> Void)?
    private(set) var mapping: WorkspaceMapping?

    init?(display: Displays.Info, axis: FlipAxis) {
        guard let screen = display.screen else {
            Log.line("FlipController: no NSScreen for display \(display.id)"); return nil
        }
        self.displayID = display.id
        self.uuid = display.uuid
        self.axis = axis
        self.overlay = OverlayWindow(screen: screen, axis: axis)
    }

    func start() {
        let pBounds = CGDisplayBounds(displayID)
        let w = Int(pBounds.width)
        let h = Int(pBounds.height)
        createdOutputSize = pBounds.size
        guard let vd = VirtualDisplay(width: w, height: h, name: "ScreenFlip Workspace", serial: displayID) else {
            Log.line("FlipController: failed to create virtual display for output \(displayID)"); return
        }
        vd.onTerminated = { [weak self] in
            guard let self else { return }
            // The workspace is gone: drop it so the capture-restart loop halts and
            // reconcile() tears this controller down and builds a fresh one.
            self.virtual = nil
            self.onNeedsReconcile?()
        }
        virtual = vd

        // Arrange: anchor | V (workspace), with P (physical output) hanging off V's
        // bottom-right CORNER. The cursor crosses anchor->V natively (V acts as a
        // normal display to the anchor's right). Corner contact keeps the arrangement
        // legal (displays must touch) but leaves no shared edge, so the cursor cannot
        // roll off the far side of the workspace onto P — where the OS would draw a
        // real, unmirrored cursor on top of the flipped picture. MirrorInput's edge
        // guard backstops this.
        //
        // The anchor is a live-resolved physical display OTHER than P: anchoring on
        // "the main display" breaks when P itself is main, and anchoring on a stale
        // Info breaks after hotplug. Our own workspaces are never anchors.
        let physical = Displays.physical()
        let anchor = physical.first { $0.id != displayID && $0.isMain }
                  ?? physical.first { $0.id != displayID }
        if let anchor {
            let a = CGDisplayBounds(anchor.id)
            let vOrigin = CGPoint(x: a.maxX, y: a.minY)
            let pOrigin = CGPoint(x: a.maxX + CGFloat(w), y: a.minY + CGFloat(h))
            Displays.setOrigins([(vd.displayID, vOrigin), (displayID, pOrigin)])
            Log.line("arranged: anchor \(anchor.id).maxX=\(a.maxX) -> V@\(vOrigin), P@\(pOrigin) (corner contact)")
        } else {
            // P is the only physical display. Give V a shared edge on P's right so the
            // cursor can still reach the workspace at all; the edge guard sweeps it off
            // P. Degraded but not stranded.
            let vOrigin = CGPoint(x: pBounds.maxX, y: pBounds.minY)
            Displays.setOrigins([(vd.displayID, vOrigin)])
            Log.line("arranged: no anchor (P is the only display) -> V@\(vOrigin) (shared edge)")
        }

        mapping = WorkspaceMapping(pDisplayID: displayID, vDisplayID: vd.displayID)

        repositionOverlay()
        overlay.orderFrontRegardless()
        capture.onSurface = { [weak self] s in self?.overlay.present(surface: s) }
        capture.onError = { [weak self] m in
            guard let self else { return }
            Log.line("output \(self.displayID) capture error: \(m)")
            self.scheduleCaptureRestart()
        }
        capture.start(displayID: vd.displayID)
        Log.line("FlipController started: P=\(displayID) shows flipped workspace vID=\(vd.displayID) vBounds=\(CGDisplayBounds(vd.displayID))")
    }

    /// False once the virtual display failed to start or was terminated by the system —
    /// reconcile() tears such controllers down and recreates them with a fresh workspace.
    var workspaceAlive: Bool { virtual != nil }

    /// True when the physical output no longer matches the size the workspace was built
    /// for (resolution change, reconnect at different mode). The workspace must be
    /// rebuilt: capturing at the stale size skews the picture and fences the cursor
    /// into only part of the output.
    var needsRebuild: Bool {
        let live = CGDisplayBounds(displayID).size
        return !live.equalTo(.zero) && !live.equalTo(createdOutputSize)
    }

    /// Keep the overlay covering the physical output after arrangement changes.
    /// The frame is computed straight from live CG bounds: NSScreen's list refreshes
    /// asynchronously after a reconfiguration, and a lookup racing that refresh used
    /// to leave the overlay parked over a different (sometimes the main) display.
    func repositionOverlay() {
        let cg = CGDisplayBounds(displayID)
        guard !cg.isEmpty else { return }
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        let frame = NSRect(x: cg.minX, y: mainH - cg.maxY, width: cg.width, height: cg.height)
        overlay.setFrame(frame, display: true)
    }

    /// replayd occasionally tears the stream down mid-session (sleep/wake, daemon
    /// restart) — sometimes without even an error object. Treat stream death as
    /// transient: bring the capture back up instead of leaving a frozen overlay.
    /// Runs on the main queue (capture reports errors there). Keeps retrying every
    /// few seconds while the workspace exists, so it also recovers when a failed
    /// restart attempt itself reports an error.
    private var restartPending = false
    private func scheduleCaptureRestart() {
        guard virtual != nil, !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard let vd = self.virtual else { return }   // stopped in the meantime
            Log.line("output \(self.displayID): restarting capture of workspace \(vd.displayID)")
            self.capture.start(displayID: vd.displayID)
        }
    }

    func stop() {
        capture.stop()
        overlay.orderOut(nil)
        virtual?.destroy()
        virtual = nil
        mapping = nil
        Log.line("FlipController stopped for output \(displayID)")
    }
}
