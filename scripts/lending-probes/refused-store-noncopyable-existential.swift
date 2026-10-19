// expect-line: 10
// expect: implicit conversion to 'any FanRestoring & ~Copyable' is consuming
// Kept by storing it in a noncopyable existential: the conversion consumes a borrowed value.
@testable import AeolusHelper

actor Keeper {
    var kept: (any FanRestoring & ~Copyable)?

    func keep<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
        kept = handback
    }
}
