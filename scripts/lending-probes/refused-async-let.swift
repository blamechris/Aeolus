// expect: borrowed and cannot be consumed|consum|noncopyable
// Kept by an async let, a child task started beside the borrow.
@testable import AeolusHelper

func handBackBeside<Handback: FanRestoring & ~Copyable>(
    _ handback: borrowing Handback
) async -> Set<Int> {
    async let early = handback.restoreToAutomatic(fans: [0], because: .leaseExpired)
    return await early
}
