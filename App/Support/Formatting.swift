import Foundation

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
