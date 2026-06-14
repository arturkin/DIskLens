import Foundation
import DiskLensCore

/// Reads a volume's capacity and free space from the filesystem.
///
/// Only returns a reading when `root` is itself a volume root (the whole disk or
/// a mounted volume) — free space is meaningless relative to a sub-folder, so a
/// folder scan returns `nil` and renders without free-space wedges.
enum VolumeProbe {
    static func usage(forScannedRoot root: URL) -> VolumeUsage? {
        let std = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? std.resourceValues(forKeys: keys),
              let volumeURL = values.volume,
              volumeURL.standardizedFileURL.path == std.path,   // only at the volume root
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity
        else { return nil }
        return VolumeUsage(capacity: Int64(total), free: Int64(available))
    }
}
