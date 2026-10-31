// expect-line: 16
// expect: actor-isolated property 'signal' can not be referenced from a nonisolated context
// see: the `@available(*, unavailable) extension HealthSignal: Sendable` below the type in HealthSignal.swift (#541)
// Not a lending shape. `HelperClient` publishes its health only on its own actor, and what keeps a
// `nonisolated` method of the actor from publishing too is that `HealthSignal` is not `Sendable`: a
// `let` of a `Sendable` type is readable from `nonisolated` code, and one of any other type is
// isolated to the actor. `HealthSignal` has only `Sendable` members, so the compiler would infer
// the conformance, and the `unavailable` extension is what withholds it. This probe is that shape.
// It goes red, by compiling, if the extension goes. `@testable`, because the type is `internal`.
@testable import AeolusXPCClient

actor Client {
    private let signal = HealthSignal(startingWith: .idle)

    nonisolated func publishFromAnywhere() {
        signal.publish(.interrupted)
    }
}
