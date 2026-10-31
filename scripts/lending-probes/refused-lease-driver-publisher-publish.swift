// expect-line: 16
// expect: actor-isolated property 'publisher' can not be referenced from a nonisolated context
// see: the `@available(*, unavailable) extension LeaseDriverPublisher: Sendable` below the type in LeaseDriverPublisher.swift (#541)
// Not a lending shape. `LeaseDriver` publishes its states only on its own actor, and what keeps a
// `nonisolated` method of the actor from publishing too is that `LeaseDriverPublisher` is not
// `Sendable`: a `let` of a `Sendable` type is readable from `nonisolated` code, and one of any
// other type is isolated to the actor. The publisher has only `Sendable` members, so the compiler
// would infer the conformance, and the `unavailable` extension is what withholds it. This probe is
// that shape. It goes red, by compiling, if the extension goes. `@testable`, because it is `internal`.
@testable import AeolusLeaseControl

actor Driver {
    private let publisher = LeaseDriverPublisher(startingWith: .idle)

    nonisolated func publishFromAnywhere() {
        publisher.publishEvidenceChange(.idle)
    }
}
