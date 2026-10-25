import AeolusXPC
import FanKit
import Foundation

// What the driver asks for a lease with, and what it keeps about each request: the holder text a
// request carries, the records of an acquisition, a grant and a release in flight, and the renewal
// interval a grant is given.
//
// **Nothing here touches the driver's state**, which is why it can live outside
// `LeaseDriver.swift` (#504); everything that does stays `private` there. The records are
// `internal` only so that the driver's `private` properties in that file can hold them. The driver
// makes every one it uses and keeps it there, so naming the type reaches none of the driver's.
extension LeaseDriver {

    /// What the app calls itself in a lease: `Aeolus.app` and its `CFBundleShortVersionString`.
    public static func holderDescription(shortVersion: String?) -> String {
        guard let shortVersion, !shortVersion.isEmpty else { return "Aeolus.app" }
        return "Aeolus.app \(shortVersion)"
    }

    /// The grant the driver holds: the lease, its fans, and the schedule it is renewed on.
    struct Grant {
        var lease: Lease
        let fans: [Int]
        let interval: Duration
        /// The ticket epoch from which a snapshot is evidence about this lease itself: set when
        /// the grant arrives.
        let leaseJudgedFrom: UInt64
        /// The ticket epoch from which a snapshot is evidence about this lease's fans: set when the
        /// first `apply` under it is answered with success, `nil` until then.
        var fansJudgedFrom: UInt64?
    }

    /// A release in flight: which one, of which lease, and its task.
    struct PendingRelease {
        let id: UInt64
        /// `nil` for a release asked for while the lease was still being acquired.
        let lease: Lease?
        let task: Task<ReleaseOutcome, Never>
    }

    /// An acquisition in flight.
    struct Acquisition {
        let id: UInt64
        /// The latest target asked for while the request is in flight.
        var target: LeaseTarget
        /// Whether a release was asked for while the request was in flight.
        var releaseOnArrival = false
    }

    /// A third of the shorter TTL. A granted TTL outside the range the helper validates is not
    /// believed, so a malformed grant cannot make the heartbeat spin.
    static func heartbeatInterval(
        asked: TimeInterval, granted: TimeInterval
    ) -> Duration {
        let believed = AeolusXPCValidation.leaseTTLRange.contains(granted) ? granted : asked
        return Duration.seconds(min(asked, believed)) / 3
    }
}
