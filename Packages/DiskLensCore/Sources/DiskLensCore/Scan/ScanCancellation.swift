import Foundation
import os

/// A thread-safe cancellation token for a running scan.
///
/// The scanner checks `isCancelled` periodically and throws `CancellationError`
/// when set. `Sendable`, so the UI can hold one and cancel from another task.
public final class ScanCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() {
        state.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        state.withLock { $0 }
    }
}
