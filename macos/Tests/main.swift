import CoreGraphics
import Foundation

private var failures = 0

private func expect(_ actual: CGPoint?, _ expected: CGPoint, _ name: String) {
    guard let actual,
          abs(actual.x - expected.x) < 0.0001,
          abs(actual.y - expected.y) < 0.0001 else {
        failures += 1
        print("FAIL \(name): got \(String(describing: actual)), expected \(expected)")
        return
    }
    print("PASS \(name)")
}

let hd = CGRect(x: 0, y: 0, width: 1920, height: 1080)
expect(FlipGeometry.horizontalMirror(point: CGPoint(x: 0, y: 0), from: hd, to: hd),
       CGPoint(x: 1919, y: 0), "left edge maps inside right edge")
expect(FlipGeometry.horizontalMirror(point: CGPoint(x: 1919, y: 1079), from: hd, to: hd),
       CGPoint(x: 0, y: 1079), "right edge maps to left edge")

let workspace = CGRect(x: 2000, y: -200, width: 101, height: 51)
let output = CGRect(x: -1000, y: 400, width: 201, height: 101)
expect(FlipGeometry.horizontalMirror(point: CGPoint(x: 2050, y: -175), from: workspace, to: output),
       CGPoint(x: -900, y: 450), "offset and scaled midpoint")
expect(FlipGeometry.horizontalMirror(point: CGPoint(x: 1900, y: -500), from: workspace, to: output),
       CGPoint(x: -800, y: 400), "out-of-range point clamps")

if FlipGeometry.horizontalMirror(point: .zero, from: .zero, to: hd) != nil {
    failures += 1
    print("FAIL empty source is rejected")
} else {
    print("PASS empty source is rejected")
}

guard failures == 0 else {
    print("\(failures) test(s) failed")
    exit(1)
}
print("All geometry tests passed")
