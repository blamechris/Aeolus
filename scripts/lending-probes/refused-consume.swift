// expect-line: 7
// expect: 'handback' is borrowed and cannot be consumed
// Kept by consuming it: a borrowed parameter cannot be consumed. Refused by the move checker.
@testable import AeolusHelper

func consumeIt<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
    _ = consume handback
}
