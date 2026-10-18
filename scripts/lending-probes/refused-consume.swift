// expect: borrowed and cannot be consumed|consum
// Kept by consuming it: a borrowed parameter cannot be consumed.
@testable import AeolusHelper

func consumeIt<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) {
    _ = consume handback
}
