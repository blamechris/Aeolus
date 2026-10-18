// expect: borrowed and cannot be consumed|consum|noncopyable
// Kept by a Task that outlives the call.
@testable import AeolusHelper

func handBackLater<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
    Task { _ = await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) }
}
