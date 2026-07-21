import AppKit
import CoreGraphics
import Foundation

Log.reset()
let physicalBefore = Displays.physical().map(\.id)

guard let workspace = VirtualDisplay(width: 800, height: 600,
                                     name: "ScreenFlip Compatibility Probe", serial: 0x5F00) else {
    fputs("FAIL: CGVirtualDisplay could not be created\n", stderr)
    exit(1)
}

let id = workspace.displayID
let bounds = CGDisplayBounds(id)
let vendor = CGDisplayVendorNumber(id)
let product = CGDisplayModelNumber(id)
let hiddenFromOutputs = !Displays.physical().contains { $0.id == id }

print("Created virtual display id=\(id) bounds=\(bounds) vendor=\(vendor) product=\(product)")
print("Physical displays before probe: \(physicalBefore)")

guard id != 0,
      Int(bounds.width) == 800,
      Int(bounds.height) == 600,
      vendor == Displays.workspaceVendorID,
      product == Displays.workspaceProductID,
      hiddenFromOutputs else {
    fputs("FAIL: virtual display identity, size, or output filtering is incorrect\n", stderr)
    workspace.destroy()
    exit(1)
}

workspace.destroy()
print("PASS: private virtual-display API and output filtering are operational")
