import Foundation

/// Removes nodes from a tree (by identity) and recomputes ancestor sizes/counts,
/// so the UI can reflect deletions immediately without a full rescan.
///
/// A directory's own overhead (its `sizeOnDisk` minus the sum of its children)
/// is preserved; only the removed children's contribution is subtracted.
public enum TreePruner {
    public static func prune(_ tree: FileTree, removing ids: Set<ObjectIdentifier>) -> FileTree {
        guard !ids.isEmpty else { return tree }
        let newRoot = prune(tree.root, ids) ?? FileNode(
            name: tree.root.name, isDirectory: tree.root.isDirectory,
            sizeOnDisk: 0, logicalSize: 0, modified: tree.root.modified,
            fileCount: 0, flags: tree.root.flags, children: [])
        return FileTree(root: newRoot, scannedRoot: tree.scannedRoot)
    }

    private static func prune(_ node: FileNode, _ ids: Set<ObjectIdentifier>) -> FileNode? {
        if ids.contains(ObjectIdentifier(node)) { return nil }
        guard !node.children.isEmpty else { return node }

        var kept: [FileNode] = []
        kept.reserveCapacity(node.children.count)
        for child in node.children {
            if let survivor = prune(child, ids) { kept.append(survivor) }
        }
        if kept.count == node.children.count {
            // Nothing beneath this node changed; reuse it as-is.
            return node
        }

        let oldKids = node.children.reduce(into: (size: Int64(0), logical: Int64(0), files: Int32(0))) {
            $0.size += $1.sizeOnDisk; $0.logical += $1.logicalSize; $0.files += $1.fileCount
        }
        let newKids = kept.reduce(into: (size: Int64(0), logical: Int64(0), files: Int32(0))) {
            $0.size += $1.sizeOnDisk; $0.logical += $1.logicalSize; $0.files += $1.fileCount
        }
        return FileNode(
            name: node.name, isDirectory: node.isDirectory,
            sizeOnDisk: node.sizeOnDisk - oldKids.size + newKids.size,
            logicalSize: node.logicalSize - oldKids.logical + newKids.logical,
            modified: node.modified,
            fileCount: node.fileCount - oldKids.files + newKids.files,
            flags: node.flags, children: kept)
    }
}
