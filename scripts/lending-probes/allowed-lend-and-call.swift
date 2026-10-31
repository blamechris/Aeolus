// The positive control: a borrowed restorer is called, and that is all. It must compile, or every
// refusal below could be the import failing rather than the compiler refusing the shape.
@testable import AeolusHelper

func lendAndCall<Handback: FanRestoring & ~Copyable>(
    _ handback: borrowing Handback
) async -> Set<Int> {
    let first = await handback.restoreToAutomatic(fans: [0], because: .leaseExpired)
    let second = await handback.restoreToAutomatic(fans: [1], because: .leaseExpired)
    return first.union(second)
}
