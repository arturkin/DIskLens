import SwiftUI
import DiskLensCore

/// A row in the list/table view, wrapping a child node with sortable fields.
struct FileRow: Identifiable {
    let node: FileNode
    let parentSize: Int64

    var id: ObjectIdentifier { ObjectIdentifier(node) }
    var name: String { node.name }
    var size: Int64 { node.sizeOnDisk }
    var fraction: Double { parentSize > 0 ? Double(node.sizeOnDisk) / Double(parentSize) : 0 }
    var modifiedSort: Double { node.modified?.timeIntervalSince1970 ?? 0 }
    var kindSort: String { node.isDirectory ? "0dir" : "1file" }

    var modifiedText: String {
        node.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
    }
    var icon: String {
        if node.flags.contains(.package) { return "shippingbox.fill" }
        if node.flags.contains(.symlink) { return "arrow.up.right.square" }
        if node.flags.contains(.aggregatedSmallFiles) { return "ellipsis.circle" }
        return node.isDirectory ? "folder.fill" : "doc"
    }
}

/// Sortable table of the focus node's children. Double-click drills into a
/// directory. (Cleanup actions are added in M5.)
struct ListTableView: View {
    let focus: FileNode
    var onSelect: (FileNode) -> Void

    @State private var sortOrder = [KeyPathComparator(\FileRow.size, order: .reverse)]

    private var rows: [FileRow] {
        focus.children
            .map { FileRow(node: $0, parentSize: focus.sizeOnDisk) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Label(row.name, systemImage: row.icon)
                    .lineLimit(1)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Size", value: \.size) { row in
                Text(Format.bytes(row.size)).monospacedDigit()
            }
            .width(90)

            TableColumn("% of parent", value: \.fraction) { row in
                ProgressView(value: row.fraction)
                    .controlSize(.small)
                    .frame(maxWidth: 80)
            }
            .width(110)

            TableColumn("Modified", value: \.modifiedSort) { row in
                Text(row.modifiedText).foregroundStyle(.secondary)
            }
            .width(110)
        }
        .contextMenu(forSelectionType: FileRow.ID.self) { _ in
            // M5 adds Reveal/Trash/Collection here.
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                onSelect(row.node)
            }
        }
    }
}
