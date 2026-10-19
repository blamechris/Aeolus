// expect-line: 10
// expect: cannot assign value of type 'Handback' to type '\(any FanRestoring\)\?'
// Kept by storing it in an actor's existential: refused by the type checker.
@testable import AeolusHelper

actor Keeper {
    var kept: (any FanRestoring)?

    func keep<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
        kept = handback
    }
}
