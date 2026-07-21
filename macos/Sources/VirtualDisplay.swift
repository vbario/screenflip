import Foundation
import CoreGraphics

/// Creates and owns a headless virtual display via the private CGVirtualDisplay API.
/// The display exists only while this object is alive (vanishes when released / app quits).
final class VirtualDisplay {
    private var display: CGVirtualDisplay?
    private var descriptor: CGVirtualDisplayDescriptor?
    let width: Int
    let height: Int
    private(set) var displayID: CGDirectDisplayID = 0
    var onTerminated: (() -> Void)?

    init?(width: Int, height: Int, name: String, serial: UInt32) {
        self.width = width
        self.height = height

        let desc = CGVirtualDisplayDescriptor()
        desc.name = name
        desc.maxPixelsWide = UInt32(width)
        desc.maxPixelsHigh = UInt32(height)
        // Pick a physical size that yields ~109 dpi (typical desktop monitor).
        desc.sizeInMillimeters = CGSize(width: Double(width) / 109.0 * 25.4,
                                        height: Double(height) / 109.0 * 25.4)
        desc.productID = Displays.workspaceProductID
        desc.vendorID = Displays.workspaceVendorID
        desc.serialNum = serial
        desc.queue = DispatchQueue(label: "io.vbar.screenflip.vd.\(serial)")
        desc.terminationHandler = { [weak self] in
            DispatchQueue.main.async {
                Log.line("VirtualDisplay terminated by system")
                self?.onTerminated?()
            }
        }

        guard let d = CGVirtualDisplay(descriptor: desc) else {
            Log.line("VirtualDisplay: init failed"); return nil
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        guard let mode = CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60) else {
            Log.line("VirtualDisplay: mode init failed"); return nil
        }
        settings.modes = [mode]
        guard d.apply(settings) else { Log.line("VirtualDisplay: applySettings failed"); return nil }

        self.descriptor = desc
        self.display = d
        self.displayID = d.displayID
        Log.line("VirtualDisplay created id=\(displayID) \(width)x\(height)")
    }

    func destroy() {
        display = nil
        descriptor = nil
        if displayID != 0 { Log.line("VirtualDisplay \(displayID) destroyed"); displayID = 0 }
    }

    deinit { destroy() }
}
