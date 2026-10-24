import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// Screens, leases and driver states for the `FanControlPresentation` suites. Namespaced, so
/// nothing here can shadow a global helper another suite in this target declares.
enum FanControlFixtures {

    typealias Support = SnapshotTestSupport
    typealias Presentation = FanControlPresentation

    /// The app's own lease, as the driver holds it.
    static let ours = Lease(holderDescription: LeaseScene.holder, expiresAt: Date())
    /// Another client's lease, which says so.
    static let theirs = Lease(holderDescription: "fanctl 0.3.0", expiresAt: Date())
    /// Another client's lease whose holder string is ours, word for word. Only its identifier
    /// tells it apart.
    static let impostor = Lease(holderDescription: LeaseScene.holder, expiresAt: Date())

    /// Text with a right-to-left override, a newline and a line separator in it. Cleaned, it is
    /// `cleaned`.
    static let hostile = "x\u{202E}y\nz\u{2028}w"
    static let cleaned = "xyzw"

    /// A fan the helper reports held under a lease: manual, offered, and a positive held target.
    static func heldFan(_ index: Int, target: Double = 3000) -> FanState {
        Support.fan(index, mode: .manualFixed, availability: .available, target: target)
    }

    /// A fan the helper reports cleared to automatic, and offers.
    static func clearedFan(_ index: Int) -> FanState {
        Support.fan(index, mode: .automatic, availability: .available)
    }

    /// What the window has: the inputs, and the fan rows beside them.
    struct Screen {
        let inputs: Presentation.Inputs
        let rows: [FanPollingReading]
    }

    /// What `PollingViewModel` puts on screen for `snapshot`: the rows `SnapshotReadings` makes of
    /// it, and the inputs it publishes beside them. `FanControlInputsTests` holds this to the view
    /// model itself.
    static func screen(_ snapshot: SystemSnapshot, driver: LeaseDriverState) -> Screen {
        Screen(
            inputs: Presentation.Inputs(
                controlSource: .helperSnapshot(activeLease: snapshot.activeLease),
                thermalEmergency: snapshot.isThermalEmergencyActive ? .active : .inactive,
                renderedSnapshot: snapshot, driver: driver),
            rows: SnapshotReadings.fans(in: snapshot))
    }

    /// What it shows once a snapshot's claims are withdrawn, or before there were any: the rows of
    /// `snapshot` with every claim taken away for `why`, and nothing on screen to judge.
    static func withdrawn(
        _ why: ControlNotTracked, driver: LeaseDriverState,
        from snapshot: SystemSnapshot = Support.snapshot(fans: [heldFan(0)])
    ) -> Screen {
        Screen(
            inputs: Presentation.Inputs(
                controlSource: .notTracked(why), thermalEmergency: .unknown, renderedSnapshot: nil,
                driver: driver),
            rows: SnapshotReadings.fans(in: snapshot).map { $0.untracked(why) })
    }

    /// The presentation of fan `index` on `screen`.
    static func present(_ index: Int, on screen: Screen) throws -> Presentation {
        let row = try #require(screen.rows.first { $0.index == index }, "no row for fan \(index)")
        return Presentation(reading: row, given: screen.inputs)
    }

    static func held(_ lease: Lease, fans: [Int], _ phase: HeldLease.Phase) -> LeaseDriverState {
        .held(HeldLease(lease: lease, fans: fans, phase: phase))
    }

    static func target(_ speeds: [Int: Double]) throws -> LeaseTarget {
        try LeaseScene.target(speeds)
    }

    /// The speed `target` holds for `index`.
    static func speed(_ target: LeaseTarget, _ index: Int) throws -> FanTargetRPM {
        try #require(target.speeds[index], "the target names no speed for fan \(index)")
    }

    static func reason(_ affordance: Presentation.Affordance) -> Presentation.Reason? {
        switch affordance {
        case .hidden(let reason), .disabled(let reason): return reason
        case .enabled: return nil
        }
    }
}

// MARK: - One tag per case, so a new case does not compile here until it is listed

extension FanControlFixtures {

    /// One tag per `LeaseDriverState` case, with no `default:` in either switch.
    enum DriverTag: CaseIterable {
        case idle, acquiring, held, releasing, released, lost, refused

        init(_ state: LeaseDriverState) {
            switch state {
            case .idle: self = .idle
            case .acquiring: self = .acquiring
            case .held: self = .held
            case .releasing: self = .releasing
            case .released: self = .released
            case .lost: self = .lost
            case .refused: self = .refused
            }
        }

        /// A state of this kind. Where the kind names fans, it names fan 0, under `ours`.
        func state() throws -> LeaseDriverState {
            switch self {
            case .idle: return .idle
            case .acquiring: return .acquiring(fans: [0])
            case .held:
                return FanControlFixtures.held(ours, fans: [0], .confirmed(try target([0: 3000])))
            case .releasing: return .releasing
            case .released: return .released
            case .lost:
                return .lost(
                    LeaseLoss(
                        lease: ours, cause: .renewal(.refused(.leaseUnknown)), afterWake: false))
            case .refused: return .refused(.manualControlUnavailable(reason: .writePathNotBuilt))
            }
        }
    }

    /// One tag per `ControlLoss` case.
    enum LossTag: CaseIterable {
        case leaseNotListed, thermalEmergency, fanNotReported, reclaimedBySystem, fanNotHeld

        init(_ loss: ControlLoss) {
            switch loss {
            case .leaseNotListed: self = .leaseNotListed
            case .thermalEmergency: self = .thermalEmergency
            case .fanNotReported: self = .fanNotReported
            case .reclaimedBySystem: self = .reclaimedBySystem
            case .fanNotHeld: self = .fanNotHeld
            }
        }

        /// Every loss of this kind, about fan 0 where it names a fan.
        var losses: [ControlLoss] {
            switch self {
            case .leaseNotListed:
                return [.leaseNotListed(listed: nil), .leaseNotListed(listed: theirs)]
            case .thermalEmergency: return [.thermalEmergency]
            case .fanNotReported: return [.fanNotReported(fan: 0)]
            case .reclaimedBySystem: return [.reclaimedBySystem(fan: 0)]
            case .fanNotHeld: return [.fanNotHeld(fan: 0)]
            }
        }

        /// For each of `losses`, a snapshot for which `controlLoss(leaseID: ours.id,
        /// covering: [0])` answers it, and otherwise shows fan 0 held under `ours`.
        var snapshots: [(snapshot: SystemSnapshot, loss: ControlLoss)] {
            switch self {
            case .leaseNotListed:
                return [
                    (Support.snapshot(fans: [heldFan(0)]), .leaseNotListed(listed: nil)),
                    (
                        Support.snapshot(fans: [heldFan(0)], activeLease: theirs),
                        .leaseNotListed(listed: theirs)
                    ),
                ]
            case .thermalEmergency:
                return [
                    (
                        Support.snapshot(
                            fans: [heldFan(0)], activeLease: ours, isThermalEmergencyActive: true),
                        .thermalEmergency
                    )
                ]
            case .fanNotReported:
                return [
                    (
                        Support.snapshot(fans: [heldFan(1)], activeLease: ours),
                        .fanNotReported(fan: 0)
                    )
                ]
            case .reclaimedBySystem:
                let reclaimed = Support.fan(
                    0, mode: .manualFixed, availability: .available, reclaimed: true)
                return [
                    (
                        Support.snapshot(fans: [reclaimed], activeLease: ours),
                        .reclaimedBySystem(fan: 0)
                    )
                ]
            case .fanNotHeld:
                let unheld = Support.fan(0, mode: .manualFixed, availability: .available)
                return [(Support.snapshot(fans: [unheld], activeLease: ours), .fanNotHeld(fan: 0))]
            }
        }
    }

    /// One tag per `LeaseLoss.Cause` case.
    enum CauseTag: CaseIterable {
        case acquireUnanswered, renewal, apply, snapshot, connection, heartbeatFailed

        init(_ cause: LeaseLoss.Cause) {
            switch cause {
            case .acquireUnanswered: self = .acquireUnanswered
            case .renewal: self = .renewal
            case .apply: self = .apply
            case .snapshot: self = .snapshot
            case .connection: self = .connection
            case .heartbeatFailed: self = .heartbeatFailed
            }
        }

        /// One failure of each kind, none of them a helper refusal that names an emergency.
        static let failures: [HelperFailure] = [
            .refused(.leaseUnknown), .failed(.helperRestarted), .other("the disk is full"),
        ]

        /// Every cause of this kind with no emergency flag set: one per failure kind for the three
        /// verbs, one per loss for a snapshot, one per connection state.
        var causes: [LeaseLoss.Cause] {
            switch self {
            case .acquireUnanswered: return Self.failures.map { .acquireUnanswered($0) }
            case .renewal: return Self.failures.map { .renewal($0) }
            case .apply: return Self.failures.map { .apply($0) }
            case .snapshot:
                return LossTag.allCases.flatMap(\.losses).map {
                    .snapshot($0, isThermalEmergencyActive: false)
                }
            case .connection: return HealthTag.departures.map { .connection($0) }
            case .heartbeatFailed: return [.heartbeatFailed]
            }
        }
    }

    /// One tag per `AeolusXPCFault` case.
    enum FaultTag: CaseIterable {
        case handshakeRequired, versionMismatch, malformedPayload, invalidParameter
        case manualControlUnavailable, leaseExpired, leaseUnknown, leaseNotHeldByThisConnection
        case thermalEmergencyActive, reclaimedBySystem, boundsImplausible, helperFailed, unknown

        init(_ fault: AeolusXPCFault) {
            switch fault {
            case .handshakeRequired: self = .handshakeRequired
            case .versionMismatch: self = .versionMismatch
            case .malformedPayload: self = .malformedPayload
            case .invalidParameter: self = .invalidParameter
            case .manualControlUnavailable: self = .manualControlUnavailable
            case .leaseExpired: self = .leaseExpired
            case .leaseUnknown: self = .leaseUnknown
            case .leaseNotHeldByThisConnection: self = .leaseNotHeldByThisConnection
            case .thermalEmergencyActive: self = .thermalEmergencyActive
            case .reclaimedBySystem: self = .reclaimedBySystem
            case .boundsImplausible: self = .boundsImplausible
            case .helperFailed: self = .helperFailed
            case .unknown: self = .unknown
            }
        }

        /// A fault of this kind with `text` in every free-text field it has.
        func fault(carrying text: String) -> AeolusXPCFault {
            switch self {
            case .handshakeRequired: return .handshakeRequired
            case .versionMismatch:
                return .versionMismatch(
                    clientVersion: 1,
                    helperRange: ProtocolVersionRange(minimumSupported: 2, current: 2))
            case .malformedPayload: return .malformedPayload(detail: text)
            case .invalidParameter: return .invalidParameter(name: text, detail: text)
            case .manualControlUnavailable: return .manualControlUnavailable(reason: .unknown(text))
            case .leaseExpired: return .leaseExpired
            case .leaseUnknown: return .leaseUnknown
            case .leaseNotHeldByThisConnection: return .leaseNotHeldByThisConnection
            case .thermalEmergencyActive: return .thermalEmergencyActive
            case .reclaimedBySystem: return .reclaimedBySystem
            case .boundsImplausible: return .boundsImplausible(fanIndex: 0, detail: text)
            case .helperFailed: return .helperFailed(detail: text)
            case .unknown: return .unknown(code: text, detail: text)
            }
        }

        /// Whether `fault(carrying:)` puts any text in the fault.
        var carriesText: Bool {
            switch self {
            case .malformedPayload, .invalidParameter, .manualControlUnavailable,
                .boundsImplausible, .helperFailed, .unknown:
                return true
            case .handshakeRequired, .versionMismatch, .leaseExpired, .leaseUnknown,
                .leaseNotHeldByThisConnection, .thermalEmergencyActive, .reclaimedBySystem:
                return false
            }
        }
    }
}
