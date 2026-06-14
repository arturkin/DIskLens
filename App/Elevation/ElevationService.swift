import Foundation
import DiskLensCore

enum ElevationError: LocalizedError, Equatable {
    case helperMissing
    case cancelled
    case scriptFailed(String)
    case resultUnreadable

    var errorDescription: String? {
        switch self {
        case .helperMissing:   "The privileged scanner helper is missing from the app bundle."
        case .cancelled:       "Authorization was cancelled."
        case .scriptFailed(let m): "The privileged scan failed: \(m)"
        case .resultUnreadable: "The scan finished but its result could not be read."
        }
    }
}

/// Runs a whole-disk scan with elevated privileges.
///
/// The v1 implementation prompts for an admin password per scan. The protocol
/// is the seam for a future persistent `SMAppService` daemon (no re-prompt,
/// scheduled scans) — a drop-in replacement.
protocol ElevationService: Sendable {
    func runPrivilegedScan(
        options: ScanOptions,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> FileTree
}

/// Launches the bundled `disklens-helper` as root via an authorization prompt
/// (`osascript … with administrator privileges`), polling a side file for
/// progress (the prompt itself returns only on completion).
struct OnDemandElevationService: ElevationService {
    func runPrivilegedScan(
        options: ScanOptions,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> FileTree {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "disklens-helper") else {
            throw ElevationError.helperMissing
        }

        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appending(path: "disklens-\(UUID().uuidString).tree")
        let progressURL = tmp.appending(path: "disklens-\(UUID().uuidString).progress")
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: progressURL)
        }

        let script = appleScript(
            helper: helper.path, root: options.root.path,
            out: outURL.path, progress: progressURL.path, options: options)

        // Poll progress while the privileged scan runs.
        let poller = Task {
            while !Task.isCancelled {
                if let p = Self.readProgress(progressURL) { progress(p) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }

        try await runOsascript(script)

        guard let data = try? Data(contentsOf: outURL),
              let tree = try? TreeCodec.decode(data) else {
            throw ElevationError.resultUnreadable
        }
        return tree
    }

    // MARK: - Command construction

    private func appleScript(helper: String, root: String, out: String, progress: String,
                             options: ScanOptions) -> String {
        var inner = "\(shellQuote(helper)) --root \(shellQuote(root))"
            + " --out \(shellQuote(out)) --progress \(shellQuote(progress))"
        if options.crossMountPoints { inner += " --cross-mounts" }
        if options.minRetainedSize > 0 { inner += " --min-size \(options.minRetainedSize)" }

        // Embed the shell command in an AppleScript string literal.
        let escaped = inner
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Run

    private func runOsascript(_ script: String) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ElevationError.scriptFailed(error.localizedDescription)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            if errText.contains("-128") || errText.localizedCaseInsensitiveContains("cancel") {
                throw ElevationError.cancelled
            }
            throw ElevationError.scriptFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private struct ProgressRecord: Decodable { let files: Int; let bytes: Int64; let path: String }

    private static func readProgress(_ url: URL) -> ScanProgress? {
        guard let data = try? Data(contentsOf: url),
              let r = try? JSONDecoder().decode(ProgressRecord.self, from: data) else { return nil }
        return ScanProgress(filesScanned: r.files, bytesScanned: r.bytes, currentPath: r.path)
    }
}
