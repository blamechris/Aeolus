// expect-line: 7
// expect: 'handback' is borrowed and cannot be consumed
// Kept by a Task that outlives the call. Refused by the move checker.
@testable import AeolusHelper

func handBackLater<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
    Task { _ = await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) }
}
