import SwiftUI
import DiskLensCore

/// Radial geometry shared by drawing and hit-testing so they stay in sync.
private struct SunburstGeometry {
    let center: CGPoint
    let hole: CGFloat
    let thickness: CGFloat
    let maxDepth: Int

    init(size: CGSize, maxDepth: Int) {
        let radius = min(size.width, size.height) / 2 * 0.96
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        hole = radius * 0.16
        thickness = max(1, (radius - hole) / CGFloat(maxDepth))
        self.maxDepth = maxDepth
    }

    func inner(_ depth: Int) -> CGFloat { hole + CGFloat(depth - 1) * thickness }
    func outer(_ depth: Int) -> CGFloat { hole + CGFloat(depth) * thickness }

    func hitTest(_ p: CGPoint, segments: [SunburstSegment]) -> SunburstSegment? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard r >= hole else { return nil }
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        let depth = Int((r - hole) / thickness) + 1
        return segments.first {
            $0.depth == depth && Double(angle) >= $0.startAngle && Double(angle) < $0.endAngle
        }
    }
}

/// Interactive sunburst: nested arcs, hover highlight, click-to-drill, click
/// the center hole to go up.
struct SunburstView: View {
    let focus: FileNode
    var hovered: FileNode?
    var maxDepth: Int = 5
    var onHover: (FileNode?) -> Void
    var onSelect: (FileNode) -> Void
    var onBack: () -> Void

    var body: some View {
        GeometryReader { geo in
            let segments = SunburstLayout.segments(focus: focus, maxDepth: maxDepth)
            let colors = SunburstColors.map(for: segments)
            let g = SunburstGeometry(size: geo.size, maxDepth: maxDepth)

            Canvas { ctx, _ in
                draw(segments: segments, colors: colors, g: g, into: &ctx)
            }
            .overlay { centerLabel(g: g) }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): onHover(g.hitTest(p, segments: segments)?.node)
                case .ended: onHover(nil)
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in handleTap(value.location, segments: segments, g: g) }
            )
        }
    }

    // MARK: Drawing

    private func draw(
        segments: [SunburstSegment], colors: [Int: Color],
        g: SunburstGeometry, into ctx: inout GraphicsContext
    ) {
        let hoveredID = hovered.map(ObjectIdentifier.init)
        for seg in segments {
            let path = annulus(
                center: g.center, inner: g.inner(seg.depth), outer: g.outer(seg.depth),
                start: seg.startAngle, end: seg.endAngle)
            let base = colors[seg.id] ?? .gray
            let isHovered = seg.node.map { ObjectIdentifier($0) == hoveredID } ?? false
            ctx.fill(path, with: .color(isHovered ? base.opacity(1.0) : base.opacity(0.92)))
            ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)),
                       lineWidth: isHovered ? 2 : 0.75)
        }
    }

    private func annulus(center: CGPoint, inner: CGFloat, outer: CGFloat,
                         start: Double, end: Double) -> Path {
        var p = Path()
        p.addArc(center: center, radius: outer, startAngle: .radians(start),
                 endAngle: .radians(end), clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: .radians(end),
                 endAngle: .radians(start), clockwise: true)
        p.closeSubpath()
        return p
    }

    @ViewBuilder
    private func centerLabel(g: SunburstGeometry) -> some View {
        VStack(spacing: 2) {
            Text(focus.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(Format.bytes(focus.sizeOnDisk))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: g.hole * 2.4)
        .help("Click the center to go up a level")
    }

    // MARK: Interaction

    private func handleTap(_ point: CGPoint, segments: [SunburstSegment], g: SunburstGeometry) {
        let dx = point.x - g.center.x, dy = point.y - g.center.y
        if hypot(dx, dy) < g.hole {
            onBack()
            return
        }
        if let node = g.hitTest(point, segments: segments)?.node {
            onSelect(node)
        }
    }
}
