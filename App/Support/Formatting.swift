import Foundation
import DiskLensCore

/// Display helpers. Uses decimal (SI) byte units to match Finder/macOS.
enum Format {
    static func bytes(_ n: Int64) -> String {
        // `.file` => decimal (SI, like Finder); `.binary` => 1024-based GiB.
        let style: ByteCountFormatStyle.Style =
            UserDefaults.standard.bool(forKey: PrefKey.useBinaryUnits) ? .binary : .file
        return max(0, n).formatted(.byteCount(style: style))
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

/// SF Symbol for a node's kind. Shared by the status bar and the hover tooltip.
enum NodeIcon {
    static func symbol(for node: FileNode) -> String {
        if node.flags.contains(.package) { return "shippingbox" }
        if node.flags.contains(.symlink) { return "arrow.up.right" }
        if node.flags.contains(.aggregatedSmallFiles) { return "ellipsis.circle" }
        return node.isDirectory ? "folder" : "doc"
    }
}
