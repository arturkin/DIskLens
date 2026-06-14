import Foundation

/// One cell in an icicle chart: a horizontal band at `depth`, spanning the
/// normalized x-range `[x, x + width]` within `[0, 1]`.
public struct IcicleTile: Sendable, Identifiable {
    public let id: Int
    public let depth: Int
    public let x: Double
    public let width: Double
    public let node: FileNode?
    public let sizeOnDisk: Int64

    public var isOther: Bool { node == nil }
}

/// Icicle layout — the same proportional, nested partition as the sunburst, but
/// laid out linearly (x-range instead of angle). Reuses `SunburstLayout` so the
/// folding and nesting behavior stays identical and tested in one place.
public enum IcicleLayout {
    public static func tiles(
        focus: FileNode,
        maxDepth: Int = 6,
        minFraction: Double = 0.004
    ) -> [IcicleTile] {
        let twoPi = 2 * Double.pi
        return SunburstLayout.segments(focus: focus, maxDepth: maxDepth, minFraction: minFraction)
            .map { seg in
                IcicleTile(
                    id: seg.id,
                    depth: seg.depth,
                    x: seg.startAngle / twoPi,
                    width: seg.angularWidth / twoPi,
                    node: seg.node,
                    sizeOnDisk: seg.sizeOnDisk
                )
            }
    }
}
