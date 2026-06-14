import SwiftUI
import DiskLensCore

/// Context-menu actions for a node, shared by the charts (acting on the hovered
/// node) and the list view (acting on the selection).
struct ChartNodeMenu: View {
    @Environment(AppModel.self) private var model
    let nodes: [FileNode]

    init(node: FileNode?) {
        self.nodes = node.map { [$0] } ?? []
    }
    init(nodes: [FileNode]) {
        self.nodes = nodes
    }

    var body: some View {
        let actionable = nodes.filter { model.actionable($0) }
        if actionable.isEmpty {
            Text("No actions")
        } else {
            if actionable.count == 1 {
                Button { model.reveal(actionable[0]) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
            Button { actionable.forEach { model.toggleCollect($0) } } label: {
                Label(collectLabel(actionable), systemImage: "tray.and.arrow.down")
            }
            Divider()
            Button(role: .destructive) { model.requestTrash(actionable) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    private func collectLabel(_ nodes: [FileNode]) -> String {
        if nodes.count == 1 {
            return model.isCollected(nodes[0]) ? "Remove from Collection" : "Add to Collection"
        }
        return "Add \(nodes.count) to Collection"
    }
}
