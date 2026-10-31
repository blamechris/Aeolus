// expect-line: 8
// expect: copy of noncopyable typed value. This is a compiler bug. Please file a bug with a small example of the bug
// Kept by a Task a defer starts, after the body has returned. Refused by the move checker, with
// its own 'this is a compiler bug' diagnostic: toolchain-fragile, which is why CI compiles it.
@testable import AeolusHelper

func handBackAfter<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
    defer { Task { _ = await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) } }
}
