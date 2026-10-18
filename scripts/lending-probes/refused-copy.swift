// expect: copy|noncopyable
// Kept by copying it: there is nothing to copy a noncopyable generic with.
@testable import AeolusHelper

func keepACopy<Handback: FanRestoring & ~Copyable>(_ handback: borrowing Handback) -> Handback {
    copy handback
}
