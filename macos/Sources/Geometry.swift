import CoreGraphics

/// Pure coordinate transforms shared by the cursor proxy and its unit tests.
enum FlipGeometry {
    /// Maps a cursor point on the hidden workspace to the horizontally mirrored
    /// hotspot on the physical output. Pixel-edge mapping keeps the result inside
    /// the output at both extremes instead of placing it one point past maxX.
    static func horizontalMirror(point: CGPoint, from source: CGRect, to output: CGRect) -> CGPoint? {
        guard source.width > 0, source.height > 0, output.width > 0, output.height > 0 else {
            return nil
        }

        let sourceSpanX = max(source.width - 1, 1)
        let sourceSpanY = max(source.height - 1, 1)
        let outputSpanX = max(output.width - 1, 0)
        let outputSpanY = max(output.height - 1, 0)
        let unitX = min(max((point.x - source.minX) / sourceSpanX, 0), 1)
        let unitY = min(max((point.y - source.minY) / sourceSpanY, 0), 1)

        return CGPoint(x: output.minX + (1 - unitX) * outputSpanX,
                       y: output.minY + unitY * outputSpanY)
    }
}
