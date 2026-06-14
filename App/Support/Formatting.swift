import Foundation

/// Display helpers. Uses decimal (SI) byte units to match Finder/macOS.
enum Format {
    static func bytes(_ n: Int64) -> String {
        // `.file` => decimal (SI) units, matching Finder.
        max(0, n).formatted(.byteCount(style: .file))
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }
}
