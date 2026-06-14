import SwiftUI
import AppKit

/// Shown after a user scan that hit many unreadable folders — nudges toward Full
/// Disk Access or an admin scan for complete results.
struct FDABanner: View {
    let count: Int
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                Text("\(count) folders couldn't be read. Grant Full Disk Access, or use an admin scan, for complete results.")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Open Settings") { openFullDiskAccess() }
                    .controlSize(.small)
                Button { dismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
