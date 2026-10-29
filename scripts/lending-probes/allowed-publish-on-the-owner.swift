// The positive control for refused-health-signal-publish.swift and
// refused-lease-driver-publisher-publish.swift: the same imports and the same two owners, each
// publishing from a method isolated to its own actor, which is how `HelperClient` and
// `LeaseDriver` do. It must compile, or the refusals next to it could be a module that failed to
// import, or a publisher that lost the member the probe names, rather than the actor keeping its
// publisher to itself.
@testable import AeolusLeaseControl
@testable import AeolusXPCClient

actor Client {
    private let signal = HealthSignal(startingWith: .idle)

    func publish() {
        signal.publish(.interrupted)
    }
}

actor Driver {
    private let publisher = LeaseDriverPublisher(startingWith: .idle)

    func publish() {
        publisher.publishEvidenceChange(.idle)
    }
}
