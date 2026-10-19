// expect-line: 10
// expect: 'handback' is borrowed and cannot be consumed
// Kept by an escaping closure an actor stores for later. Refused by the move checker.
@testable import AeolusHelper

actor Keeper {
    var later: (@Sendable () async -> Set<Int>)?

    func keep<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
        later = { await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) }
    }
}
