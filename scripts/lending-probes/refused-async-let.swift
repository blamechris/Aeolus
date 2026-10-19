// expect-line: 9
// expect: 'handback' is borrowed and cannot be consumed
// Kept by an async let, a child task started beside the borrow. Refused by the move checker.
@testable import AeolusHelper

func handBackBeside<Handback: FanRestoring & ~Copyable>(
    _ handback: borrowing Handback
) async -> Set<Int> {
    async let early = handback.restoreToAutomatic(fans: [0], because: .leaseExpired)
    return await early
}
