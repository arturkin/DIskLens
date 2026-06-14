import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.treatPackagesAsFiles) private var treatPackagesAsFiles = true
    @AppStorage(PrefKey.crossMountPoints) private var crossMountPoints = false
    @AppStorage(PrefKey.minRetainedSizeKB) private var minRetainedSizeKB = 0
    @AppStorage(PrefKey.maxRuns) private var maxRuns = 10
    @AppStorage(PrefKey.autoRescanOnLaunch) private var autoRescanOnLaunch = false
    @AppStorage(PrefKey.useBinaryUnits) private var useBinaryUnits = false

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Treat app bundles as single files", isOn: $treatPackagesAsFiles)
                Toggle("Cross volume boundaries", isOn: $crossMountPoints)
                LabeledContent("Group files smaller than") {
                    HStack {
                        TextField("", value: $minRetainedSizeKB, format: .number)
                            .frame(width: 80).labelsHidden()
                        Text("KB").foregroundStyle(.secondary)
                    }
                }
                Text("Files below this size are grouped into a “(small files)” entry to keep charts legible. 0 keeps every file.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep last \(maxRuns) scans", value: $maxRuns, in: 1...50)
                Toggle("Re-scan the last folder on launch", isOn: $autoRescanOnLaunch)
            }

            Section("Display") {
                Picker("Size units", selection: $useBinaryUnits) {
                    Text("Decimal (GB, like Finder)").tag(false)
                    Text("Binary (GiB)").tag(true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }
}
