// expect-line: 11
// expect: copy of noncopyable typed value. This is a compiler bug
// Kept by a child task a task group starts, beside the borrow. Refused by the move checker, with
// its own 'this is a compiler bug' diagnostic: toolchain-fragile, which is why CI compiles it.
@testable import AeolusHelper

func handBackInAGroup<Handback: FanRestoring & ~Copyable>(
    _ handback: borrowing Handback
) async -> Set<Int> {
    await withTaskGroup(of: Set<Int>.self) { group in
        group.addTask { await handback.restoreToAutomatic(fans: [0], because: .leaseExpired) }
        return await group.reduce(into: Set<Int>()) { $0.formUnion($1) }
    }
}
