import SwiftUI
import Charts
import DiskLensCore

/// Horizontal bar chart of the focus node's largest children. Click a bar to
/// drill into a directory.
struct BarView: View {
    let focus: FileNode
    var onSelect: (FileNode) -> Void

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
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let y = value.location.y - geo[plotFrame].origin.y
                        if let name: String = proxy.value(atY: y),
                           let hit = items.first(where: { $0.name == name }) {
                            onSelect(hit.node)
                        }
                    })
            }
        }
        .padding(.trailing, 48)
    }
}
