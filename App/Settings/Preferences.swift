import Foundation
import SwiftUI
import DiskLensCore

/// UserDefaults keys and helpers shared by SettingsView (`@AppStorage`) and the
/// model (which reads them to build `ScanOptions`).
enum PrefKey {
    static let treatPackagesAsFiles = "treatPackagesAsFiles"
    static let crossMountPoints = "crossMountPoints"
    static let minRetainedSizeKB = "minRetainedSizeKB"
    static let maxRuns = "maxRuns"
    static let autoRescanOnLaunch = "autoRescanOnLaunch"
    static let useBinaryUnits = "useBinaryUnits"
    static let appearance = "appearance"
}

/// App-wide appearance override. `system` follows macOS; the app ships dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` => follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum Preferences {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.treatPackagesAsFiles: true,
            PrefKey.crossMountPoints: false,
            PrefKey.minRetainedSizeKB: 0,
            PrefKey.maxRuns: 10,
            PrefKey.autoRescanOnLaunch: false,
            PrefKey.useBinaryUnits: false,
            PrefKey.appearance: AppAppearance.dark.rawValue,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var treatPackagesAsFiles: Bool { d.bool(forKey: PrefKey.treatPackagesAsFiles) }
    static var crossMountPoints: Bool { d.bool(forKey: PrefKey.crossMountPoints) }
    static var minRetainedSize: Int64 { Int64(d.integer(forKey: PrefKey.minRetainedSizeKB)) * 1024 }
    static var maxRuns: Int { max(1, d.integer(forKey: PrefKey.maxRuns)) }
    static var autoRescanOnLaunch: Bool { d.bool(forKey: PrefKey.autoRescanOnLaunch) }
    static var useBinaryUnits: Bool { d.bool(forKey: PrefKey.useBinaryUnits) }

    /// Scan options for a given root, applying the current preferences.
    static func scanOptions(root: URL) -> ScanOptions {
        ScanOptions(
            root: root,
            crossMountPoints: crossMountPoints,
            treatPackagesAsFiles: treatPackagesAsFiles,
            minRetainedSize: minRetainedSize
        )
    }
}
