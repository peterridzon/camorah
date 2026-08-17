import Foundation

/// A fair, FIFO async mutex.
///
/// Actors serialise access to their state but not across `await` suspension
/// points, so an actor alone cannot keep two overlapping request/response
/// exchanges from interleaving on one socket. This does.
public actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
