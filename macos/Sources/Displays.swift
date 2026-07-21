import AppKit
import CoreGraphics

/// Helpers for enumerating displays and mapping between CoreGraphics display IDs
/// and AppKit NSScreens.
enum Displays {
    /// Vendor/product pair stamped on ScreenFlip's own virtual workspace displays,
    /// so they can be told apart from real panels wherever displays are enumerated.
    static let workspaceVendorID: UInt32 = 0x5346   // 'SF'
    static let workspaceProductID: UInt32 = 0x5350  // 'SP'

    struct Info {
        let id: CGDirectDisplayID
        let uuid: String            // stable across reboots (numeric id is not)
        let bounds: CGRect          // global CG coords (top-left origin)
        let isMain: Bool
        let isBuiltin: Bool
        let isWorkspace: Bool       // one of our own headless virtual workspaces
        let screen: NSScreen?

        /// Human-friendly label for the menu, e.g. "LG FULL HD (1920×1080)".
        var label: String {
            let res = "\(Int(bounds.width))×\(Int(bounds.height))"
            let name = screen?.localizedName ?? (isMain ? "Main Display" : "Display \(id)")
            return "\(name) (\(res))" + (isMain ? " — main" : "")
        }
    }

    static func all() -> [Info] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            Info(id: id,
                 uuid: uuidString(for: id),
                 bounds: CGDisplayBounds(id),
                 isMain: CGDisplayIsMain(id) != 0,
                 isBuiltin: CGDisplayIsBuiltin(id) != 0,
                 isWorkspace: CGDisplayVendorNumber(id) == workspaceVendorID
                           && CGDisplayModelNumber(id) == workspaceProductID,
                 screen: screen(for: id))
        }
    }

    /// Real panels only. The menu, reconcile and arrangement snapshots must never
    /// treat one of our own workspaces as a flippable / restorable display — a
    /// workspace that sneaks into the selection cascades into flipping a virtual
    /// display, and one in a snapshot pins a dead ID into the restore map.
    static func physical() -> [Info] { all().filter { !$0.isWorkspace } }

    /// Physical displays that are safe to use as flipped outputs. The main display
    /// anchors the hidden workspace arrangement and hosts the primary menu bar, so it
    /// cannot itself be the output.
    static func eligibleOutputs() -> [Info] { physical().filter { !$0.isMain } }

    /// Stable per-display identifier (survives reboot / reconnection).
    static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return "id-\(id)"
        }
        return CFUUIDCreateString(nil, cf) as String
    }

    static func main() -> Info? { physical().first { $0.isMain } }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // MARK: Arrangement save / set / restore

    /// Snapshot every physical display's origin, keyed by UUID — display IDs are not
    /// stable across disconnect/reconnect, so an ID-keyed snapshot restores nothing
    /// (or the wrong display) after a hotplug cycle mid-session.
    static func snapshotOrigins() -> [String: CGPoint] {
        var map: [String: CGPoint] = [:]
        for d in physical() { map[d.uuid] = d.bounds.origin }
        return map
    }

    /// Apply a set of display origins in a single reconfiguration transaction.
    static func setOrigins(_ origins: [(CGDirectDisplayID, CGPoint)]) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (id, o) in origins {
            CGConfigureDisplayOrigin(config, id, Int32(o.x.rounded()), Int32(o.y.rounded()))
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    static func restoreOrigins(_ map: [String: CGPoint]) {
        let pairs = physical().compactMap { d in map[d.uuid].map { (d.id, $0) } }
        setOrigins(pairs)
        Log.line("restored display arrangement for \(pairs.count) of \(map.count) display(s)")
    }
}
