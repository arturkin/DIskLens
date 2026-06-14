import AppKit

/// Thin wrapper over Finder operations. Trash is recoverable; we never `rm`.
enum TrashService {
    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Moves the item to the Trash. Throws if it doesn't exist or isn't deletable
    /// (e.g. a root-owned file from an admin scan).
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
