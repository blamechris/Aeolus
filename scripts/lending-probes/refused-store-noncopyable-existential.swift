// expect: consum
// Kept by storing it in a noncopyable existential: the conversion consumes a borrowed value.
@testable import AeolusHelper

actor Keeper {
    var kept: (any FanRestoring & ~Copyable)?

    func keep<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
        kept = handback
    }
}
