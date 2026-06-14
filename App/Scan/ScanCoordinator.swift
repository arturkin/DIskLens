import Foundation
import DiskLensCore

/// Runs the CPU-bound `Scanner` off the main actor and funnels progress back
/// through a `Sendable` callback. The caller hops progress to the main actor.
enum ScanCoordinator {
    static func run(
        _ options: ScanOptions,
        cancellation: ScanCancellation,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> DiskScanner.Result {
        try await Task.detached(priority: .userInitiated) {
            try DiskScanner().scan(options, cancellation: cancellation, progress: progress)
        }.value
    }
}
