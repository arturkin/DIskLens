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

    public init(
        id: UUID = UUID(),
        date: Date,
        scannedRoot: String,
        mode: ScanMode,
        volumeName: String?,
        totalSize: Int64,
        fileCount: Int,
        durationMs: Int,
        appVersion: String
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
    }
}
