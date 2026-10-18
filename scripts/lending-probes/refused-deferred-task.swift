// expect: borrowed and cannot be consumed|consum|noncopyable
// Kept by a Task a defer starts, after the body has returned.
@testable import AeolusHelper

func handBackAfter<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
    defer { Task { _ = await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) } }
}
