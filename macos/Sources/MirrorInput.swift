import AppKit
import CoreGraphics

/// Draws the on-screen cursor proxy for virtual flipped workspaces.
///
/// The cursor lives NATIVELY on the headless workspace V (no input interception at all —
/// nothing touches the mouse on any display). Because V has no panel, its cursor is
/// invisible, so we poll the cursor position and, whenever it's on a workspace, draw a
/// synthetic cursor on the physical output P at the horizontally-mirrored position — i.e.
/// exactly where V's flipped capture shows the spot the cursor is really on.
///
/// All geometry is looked up LIVE by display ID on every tick. The mapping only carries
/// IDs: cached rects go stale the instant the OS adjusts the arrangement (hotplug,
/// resolution change, overlap resolution), and a stale rect here either fences the
/// cursor into part of the workspace or draws the proxy far from where clicks land.
///
/// Needs NO Accessibility and NO event tap.
final class MirrorInput {
    static let shared = MirrorInput()

    private var mappings: [WorkspaceMapping] = []
    private var timer: Timer?
    private let cursorWindow = CursorWindow()
    private var lastOnWorkspace = false

    /// Mirror the proxy cursor image to match the flipped content (off = normal-facing arrow).
    func setCursorFlipped(_ on: Bool) {
        cursorWindow.setFlipped(on)
        Log.line("MirrorInput(proxy): cursor flipped = \(on)")
    }

    func setMappings(_ maps: [WorkspaceMapping]) {
        mappings = maps
        Log.line("MirrorInput(proxy): \(maps.count) workspace(s)")
        if maps.isEmpty {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.line("MirrorInput(proxy): cursor proxy started (no event tap)")
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        cursorWindow.hideCursor()
    }

    private func tick() {
        guard let c = CGEvent(source: nil)?.location else { return }
        for m in mappings {
            let vRect = CGDisplayBounds(m.vDisplayID)
            guard !vRect.isEmpty else { continue }      // workspace gone → skip
            if vRect.contains(c) {
                drawProxy(at: c, mapping: m)
                return
            }
        }
        // Edge guard: the physical output P only ever shows V's mirrored picture, so the
        // cursor has no business there — were it allowed to stay, the OS would draw a
        // real, unmirrored cursor on top of the flipped content and its motion would
        // read backwards. If it slips onto P anyway (shared edge after the OS adjusts
        // the arrangement, an app-initiated warp, a fast flick), pin it back to the
        // nearest point of the workspace. This touches the cursor ONLY on P, a display
        // the user cannot meaningfully use; input everywhere else stays native.
        for m in mappings {
            guard CGDisplayBounds(m.pDisplayID).contains(c) else { continue }
            let vRect = CGDisplayBounds(m.vDisplayID)
            guard !vRect.isEmpty else { continue }      // workspace gone → leave the cursor alone
            let pinned = CGPoint(x: min(max(c.x, vRect.minX), vRect.maxX - 1),
                                 y: min(max(c.y, vRect.minY), vRect.maxY - 1))
            CGWarpMouseCursorPosition(pinned)
            CGAssociateMouseAndMouseCursorPosition(1)   // cancel post-warp move suppression
            drawProxy(at: pinned, mapping: m)
            return
        }
        if lastOnWorkspace { cursorWindow.hideCursor(); lastOnWorkspace = false }
    }

    /// Draw the synthetic cursor on P at the horizontal mirror of workspace point `c`.
    /// Bounds are looked up live; FlipGeometry clamps and scales, so the proxy stays on
    /// the pixel the flipped capture shows for `c` even if P and V transiently disagree
    /// in size (mode change before the workspace rebuild lands).
    private func drawProxy(at c: CGPoint, mapping m: WorkspaceMapping) {
        let vRect = CGDisplayBounds(m.vDisplayID)
        let pRect = CGDisplayBounds(m.pDisplayID)
        guard let proxy = FlipGeometry.horizontalMirror(point: c, from: vRect, to: pRect) else { return }
        cursorWindow.moveHotspot(toCG: proxy)
        lastOnWorkspace = true
    }
}
