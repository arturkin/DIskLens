import Foundation

/// Whether a scan ran with normal user privileges or elevated (root) privileges.
public enum ScanMode: String, Codable, Sendable, CaseIterable {
    case user
    case admin
}

/// Lightweight metadata describing a saved scan run.
///
/// Stored in the run index so the app can list history without loading the
/// (potentially large) tree blobs.
public struct RunMetadata: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let scannedRoot: String
    public let mode: ScanMode
    public let volumeName: String?
    public let totalSize: Int64
    public let fileCount: Int
    public let durationMs: Int
    public let appVersion: String
    /// Total capacity of the scanned volume, when the root was a volume root.
    /// `nil` for folder scans and for runs recorded before free-space tracking.
    public let capacity: Int64?
    /// Free space on the scanned volume at scan time (matches Disk Utility's "Free").
    public let freeSpace: Int64?

    public init(
        id: UUID = UUID(),
        date: Date,
        scannedRoot: String,
        mode: ScanMode,
        volumeName: String?,
        totalSize: Int64,
        fileCount: Int,
        durationMs: Int,
        appVersion: String,
        capacity: Int64? = nil,
        freeSpace: Int64? = nil
    ) {
        self.id = id
        self.date = date
        self.scannedRoot = scannedRoot
        self.mode = mode
        self.volumeName = volumeName
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.durationMs = durationMs
        self.appVersion = appVersion
        self.capacity = capacity
        self.freeSpace = freeSpace
    }

    /// The volume's capacity/free reading, if this run captured one.
    public var volumeUsage: VolumeUsage? {
        guard let capacity, let freeSpace else { return nil }
        return VolumeUsage(capacity: capacity, free: freeSpace)
    }
}
