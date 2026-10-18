// expect: borrowed and cannot be consumed|consum|noncopyable|escaping
// Kept by an escaping closure an actor stores for later.
@testable import AeolusHelper

actor Keeper {
    var later: (@Sendable () async -> Set<Int>)?

    func keep<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
        later = { await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) }
    }
}
