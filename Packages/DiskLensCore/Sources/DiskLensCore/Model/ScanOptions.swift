import Foundation

/// Inputs controlling a scan.
public struct ScanOptions: Sendable {
    /// Absolute root to scan.
    public var root: URL
    /// When false (default), the scan stops at volume boundaries (different `st_dev`).
    public var crossMountPoints: Bool
    /// When true, `.app`/`.bundle` packages are treated as opaque files (not descended).
    public var treatPackagesAsFiles: Bool
    /// Files strictly below this allocated size are folded into a synthetic
    /// "(small files)" leaf per directory. 0 disables aggregation.
    public var minRetainedSize: Int64
    /// Absolute paths to skip entirely.
    public var excludePaths: [URL]

    public init(
        root: URL,
        crossMountPoints: Bool = false,
        treatPackagesAsFiles: Bool = true,
        minRetainedSize: Int64 = 0,
        excludePaths: [URL] = []
    ) {
        self.root = root
        self.crossMountPoints = crossMountPoints
        self.treatPackagesAsFiles = treatPackagesAsFiles
        self.minRetainedSize = minRetainedSize
        self.excludePaths = excludePaths
    }
}

/// Periodic progress emitted while scanning.
public struct ScanProgress: Sendable, Equatable {
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var currentPath: String

    public init(filesScanned: Int = 0, bytesScanned: Int64 = 0, currentPath: String = "") {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
    }
}
