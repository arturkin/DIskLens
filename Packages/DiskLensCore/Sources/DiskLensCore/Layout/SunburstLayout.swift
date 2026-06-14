import Foundation

/// One drawable arc in a sunburst chart.
public struct SunburstSegment: Sendable, Identifiable {
    public let id: Int
    /// 1 = innermost ring (the focus node's direct children).
    public let depth: Int
    /// Angles in radians, measured from 0, increasing. `start < end`, within `[0, 2π]`.
    public let startAngle: Double
    public let endAngle: Double
    /// The node this arc represents. `nil` for an aggregated "Other" slice.
    public let node: FileNode?
    /// Sum of sizes represented by this arc (own node, or aggregated others).
    public let sizeOnDisk: Int64

    public var isOther: Bool { node == nil }
    public var angularWidth: Double { endAngle - startAngle }
}

/// Pure sunburst layout: turns a focus node into proportional, nested arcs.
///
/// Each ring fills its parent's angular span in proportion to child sizes.
/// Arcs thinner than `minFraction` of the full circle are folded into a single
/// "Other" slice within their parent's span, keeping the chart legible and the
/// segment count bounded regardless of how many tiny files exist.
public enum SunburstLayout {
    public static func segments(
        focus: FileNode,
        maxDepth: Int = 5,
        minFraction: Double = 0.01
    ) -> [SunburstSegment] {
        var result: [SunburstSegment] = []
        var nextID = 0
        let minAngle = minFraction * 2 * .pi

        func emit(_ parent: FileNode, start: Double, end: Double, depth: Int) {
            guard depth <= maxDepth else { return }
            let kids = parent.children.filter { $0.sizeOnDisk > 0 }
            let denom = kids.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
            guard denom > 0 else { return }

            let span = end - start
            var cursor = start
            var otherSize: Int64 = 0

            // Children arrive size-sorted from the scanner; preserve that order.
            for kid in kids.sorted(by: { $0.sizeOnDisk > $1.sizeOnDisk }) {
                let width = Double(kid.sizeOnDisk) / Double(denom) * span
                if width < minAngle {
                    otherSize += kid.sizeOnDisk
                    continue
                }
                let segEnd = cursor + width
                result.append(SunburstSegment(
                    id: nextID, depth: depth, startAngle: cursor, endAngle: segEnd,
                    node: kid, sizeOnDisk: kid.sizeOnDisk))
                nextID += 1
                emit(kid, start: cursor, end: segEnd, depth: depth + 1)
                cursor = segEnd
            }

            if otherSize > 0 {
                let width = Double(otherSize) / Double(denom) * span
                result.append(SunburstSegment(
                    id: nextID, depth: depth, startAngle: cursor, endAngle: cursor + width,
                    node: nil, sizeOnDisk: otherSize))
                nextID += 1
            }
        }

        emit(focus, start: 0, end: 2 * .pi, depth: 1)
        return result
    }
}
