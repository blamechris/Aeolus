// expect-line: 9
// expect: noncopyable types cannot be conditionally cast
// Kept by casting it into a copyable existential a store could keep: refused by the type checker.
@testable import AeolusHelper

func castIt<Handback: FanRestoring & ~Copyable>(
    _ handback: borrowing Handback
) -> (any FanRestoring)? {
    handback as? any FanRestoring
}
