import SwiftUI
import Charts
import DiskLensCore

/// Horizontal bar chart of the focus node's largest children. Click a bar to
/// drill into a directory.
struct BarView: View {
    let focus: FileNode
    var onHover: (FileNode?) -> Void = { _ in }
    var onSelect: (FileNode) -> Void

    @State private var hover: ChartHoverHit?

    private struct Datum: Identifiable {
        let id: ObjectIdentifier
        let node: FileNode
        let name: String
        let size: Int64
    }

    private var data: [Datum] {
        focus.children.prefix(24).map {
            Datum(id: ObjectIdentifier($0), node: $0, name: $0.name, size: $0.sizeOnDisk)
        }
    }

    var body: some View {
        let items = data
        Chart(items) { item in
            BarMark(
                x: .value("Size", item.size),
                y: .value("Name", item.name)
            )
            .foregroundStyle(by: .value("Name", item.name))
            .annotation(position: .trailing, alignment: .leading) {
                Text(Format.bytes(item.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(Format.bytes(bytes))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { _ in
                AxisValueLabel(horizontalSpacing: 6)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let node = barNode(at: p, proxy: proxy, geo: geo, items: items)
                            onHover(node)
                            hover = node.map { ChartHoverHit(node: $0, point: p) }
                        case .ended:
                            onHover(nil)
                            hover = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        if let node = barNode(at: value.location, proxy: proxy, geo: geo, items: items) {
                            onSelect(node)
                        }
                    })
                    .chartTooltip(hover, bounds: geo.size, focus: focus)
            }
        }
        .padding(.trailing, 48)
    }

    /// The node whose bar row sits under `point` (maps the y position back to a category).
    private func barNode(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy, items: [Datum]) -> FileNode? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let y = point.y - geo[plotFrame].origin.y
        guard let name: String = proxy.value(atY: y) else { return nil }
        return items.first(where: { $0.name == name })?.node
    }
}
