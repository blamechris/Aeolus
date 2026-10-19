// expect-line: 7
// expect: 'copy' cannot be applied to noncopyable types
// Kept by copying it: there is nothing to copy a noncopyable generic with. Refused by the type checker.
@testable import AeolusHelper

func keepACopy<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) -> Handback {
    copy handback
}
