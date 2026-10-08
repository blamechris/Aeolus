import AeolusXPC
import FanKit
import Foundation
import os

@testable import AeolusHelper
@testable import fanctl

/// Snapshots number `after + 1` through `through` (all of them when `nil`) fail with
/// `fault`.
private struct SnapshotFailure {
    let after: Int
    let through: Int?
    let fault: AeolusXPCFault

    func fails(_ served: Int) -> Bool {
        served > after && (through.map { served <= $0 } ?? true)
    }
}

/// A `FanAuthority` that behaves like a helper **with** a write path, for driving `fanctl`'s
/// helper commands end to end.
///
/// It sits behind the real `HelperConnectionSession`, over a real anonymous `NSXPCListener`
/// (`ClientListenerHarness`), so every message `fanctl` sends crosses the same handshake gate,
/// payload validation and fault encoding the shipped helper applies. What it replaces is only
/// the authority — the lease table and the fans — and it models those the way ADR 0007 and
/// `LeaseAuthority` describe them: one lease at a time, a lease names its fans, releasing it
/// or losing its connection returns them to automatic, and `restoreAllToAutomatic` drops every
/// lease and returns every fan *Aeolus* is driving (a pinned fan — one a foreign tool holds, or
/// one whose handback the firmware refused — is not reached).
///
/// **Nothing here writes to a fan, and nothing pretends the shipped helper can.** The shipped
/// helper answers every lease with `writePathNotBuilt`; `refusingEveryLease(with:)` is how a
/// test reproduces that.
actor SimulatedFanAuthority: FanAuthority {

    private var fans: [FanState]
    /// Fans no Aeolus verb can return, with the reason the snapshot reports for each.
    private var pinnedFans: [Int: ManualControlAvailability.Reason] = [:]
    private var lease: Lease?
    private var leaseHolder: ConnectionID?
    private var leasedFans: Set<Int> = []
    private var isThermalEmergencyActive = false

    // Scripting.
    private var acquireRefusal: AeolusXPCFault?
    private var renewalsBeforeRefusal: Int?
    private var renewalRefusal: AeolusXPCFault = .leaseExpired
    private var reclaimAfterRenewals: Int?
    private var releaseRefusal: AeolusXPCFault?
    private var ignoresApply = false
    private var ignoresRestore = false
    private var restoreRefusal: AeolusXPCFault?
    private var snapshotsBeforeRestoreShows = 0
    private var snapshotsLeftBeforeRestoreShows: Int?
    private var releasesToAnotherHolder: String?
    private var snapshotFailure: SnapshotFailure?
    private var heldSnapshots: AsyncSignal?
    // What `fanctl set` needs: a hold that goes wrong in each of the ways the helper reports.
    private var applyRefusal: AeolusXPCFault?
    private var leaseHiddenAfterRenewals: Int?
    private var leaseShownInstead: Lease?
    private var emergencyAfterRenewals: Int?
    private var snapshotsBeforeReleaseShows = 0
    private var snapshotsLeftBeforeReleaseShows: Int?
    private var takenAfterRelease: String?

    // Records.
    private(set) var calls: [String] = []
    /// How many `restoreAllToAutomatic` messages reached this authority, refused ones
    /// included. `fanctl auto` is held to zero when nothing needs returning and to exactly one
    /// otherwise, and this is the number those assertions read.
    private(set) var restoreRequests = 0
    /// How many snapshots were served, failed ones included.
    private(set) var snapshotsServed = 0
    private(set) var acquiredRequests: [LeaseRequest] = []
    private(set) var appliedSettings: [[FanSetting]] = []
    private(set) var renewals = 0

    /// Two fans with the shipping development machine's declared range, both automatic and
    /// available.
    init(fans: [FanState] = SimulatedFanAuthority.twoFans()) {
        self.fans = fans
    }

    static func fan(
        _ index: Int,
        minimum: Double = 1350,
        maximum: Double = 5777,
        mode: FanControlMode = .automatic,
        availability: ManualControlAvailability = .available
    ) -> FanState {
        FanState(
            index: index,
            actualRPM: .measured(minimum),
            minimumRPM: .measured(minimum),
            maximumRPM: .measured(maximum),
            targetRPM: nil,
            mode: mode,
            isReclaimedBySystem: false,
            manualControlAvailability: availability)
    }

    static func twoFans() -> [FanState] { [fan(0), fan(1)] }

    // MARK: - Scripting

    func refusingEveryLease(with fault: AeolusXPCFault) { acquireRefusal = fault }

    func refusingRenewal(after successes: Int, with fault: AeolusXPCFault = .leaseExpired) {
        renewalsBeforeRefusal = successes
        renewalRefusal = fault
    }

    func reclaiming(after successes: Int) { reclaimAfterRenewals = successes }

    func refusingRelease(with fault: AeolusXPCFault) { releaseRefusal = fault }

    func ignoringApply() { ignoresApply = true }

    /// `restoreAllToAutomatic` is accepted and changes nothing: the lease stays, the fans stay.
    func ignoringRestore() { ignoresRestore = true }

    /// `restoreAllToAutomatic` is refused with `fault`.
    func refusingRestore(with fault: AeolusXPCFault) { restoreRefusal = fault }

    /// **Automatic only after N snapshots.** The restore is accepted, but the next `snapshots`
    /// snapshots still report the state from before it — the lease listed, the fans in manual —
    /// and the one after them reports the restored state. It is what makes a poll loop run more
    /// than once: the shipped helper's restore is asynchronous, and a double that applied it
    /// before the reply would let a loop that never polled pass every test.
    func settling(afterSnapshots snapshots: Int) { snapshotsBeforeRestoreShows = snapshots }

    /// Another client takes the fans again the moment the restore lands: a lease held by
    /// `holder` appears over fan 0 with the snapshot that shows the restore.
    func reacquiring(as holder: String) { releasesToAnotherHolder = holder }

    /// Every snapshot from the `count + 1`-th on fails with `fault` — or, with `times`, only the
    /// next `times` of them do, after which the helper answers again.
    func failingSnapshots(
        after count: Int, times: Int? = nil,
        with fault: AeolusXPCFault = .helperFailed(detail: "x")
    ) {
        snapshotFailure = SnapshotFailure(
            after: count, through: times.map { count + $0 }, fault: fault)
    }

    /// Every snapshot is accepted and **not answered** until `signal` fires — the helper that took
    /// the message and went quiet, which is what a client's deadline exists for. The handshake
    /// is unaffected: `hello` is answered by the session, never by this authority.
    func holdingSnapshots(until signal: AsyncSignal) { heldSnapshots = signal }

    func setThermalEmergency(_ active: Bool) { isThermalEmergencyActive = active }

    /// `apply` is refused with `fault`: the lease was granted and the speed was not.
    func refusingApply(with fault: AeolusXPCFault) { applyRefusal = fault }

    /// **A snapshot without the caller's lease ID**, while renewals still succeed. From the
    /// `renewals`-th renewal on, snapshots list `other` (or no lease at all) in place of the
    /// lease the authority holds: what a client sees when the helper has ended its lease and
    /// said nothing else.
    func listingNoLease(afterRenewals renewals: Int, showing other: Lease? = nil) {
        leaseHiddenAfterRenewals = renewals
        leaseShownInstead = other
    }

    /// A thermal emergency becomes active with the `renewals`-th renewal: the helper's override
    /// outranks the hold, and says so only in its snapshots.
    func emergency(afterRenewals renewals: Int) { emergencyAfterRenewals = renewals }

    /// **A release that lands after N snapshots.** `releaseLease` is accepted, and the next
    /// `snapshots` snapshots still list the lease and the fans as they were; the one after them
    /// shows the release. It is what makes `fanctl set`'s ending poll more than once: the
    /// shipped helper's handback is asynchronous.
    func settling(afterReleaseSnapshots snapshots: Int) { snapshotsBeforeReleaseShows = snapshots }

    /// Another client takes the fans the moment our release lands: a lease held by `holder`
    /// appears over fan 0 with the snapshot that shows the release.
    func reacquiringAfterRelease(as holder: String) { takenAfterRelease = holder }

    /// Another client's lease over `fans`, on a connection no test owns.
    func grantForeignLease(over fans: Set<Int>, holder: String = "Aeolus.app 0.3.0") {
        lease = Lease(holderDescription: holder, expiresAt: Date().addingTimeInterval(30))
        leaseHolder = ConnectionID()
        leasedFans = fans
        for index in fans { set(index, mode: .manualFixed, target: 3000) }
    }

    /// A fan some other program put in manual, which no Aeolus verb reaches.
    func markForeignManual(_ index: Int) { pin(index, as: .foreignManualControl) }

    /// A fan that no verb returns and that reports `reason`: the foreign program's fan above,
    /// the firmware that refused every handback (`restoreToAutomaticFailed`), or a reason that
    /// is only transient and never clears here.
    ///
    /// `mode` is what the fan reads. `.manualFixed` is a fan really held. **`.automatic` is the
    /// helper's report of a mode it could not read** — the unread `F<n>Md` of #178, and what an
    /// Intel Mac always says — beside a reason that says it has not cleared the fan. That
    /// combination is an ordinary helper output (the ladder restates the reason with no mode
    /// guard), and it is the one `fanctl auto` must not read as the safe state.
    func pin(
        _ index: Int, as reason: ManualControlAvailability.Reason,
        reading mode: FanControlMode = .manualFixed
    ) {
        pinnedFans[index] = reason
        set(index, mode: mode, target: mode == .automatic ? nil : 2500)
    }

    /// A fan in manual under no lease that a restore *does* return — what a crashed client
    /// leaves behind.
    func strandManual(_ index: Int) { set(index, mode: .manualFixed, target: 2500) }

    var currentLease: Lease? { lease }

    func modes() -> [FanControlMode] { fans.map(\.mode) }

    // MARK: - FanAuthority

    func snapshot() async throws -> SystemSnapshot {
        calls.append("snapshot")
        snapshotsServed += 1
        if let heldSnapshots { try await heldSnapshots.wait() }
        if let snapshotFailure, snapshotFailure.fails(snapshotsServed) {
            throw snapshotFailure.fault
        }
        if let remaining = snapshotsLeftBeforeRestoreShows {
            if remaining == 0 {
                snapshotsLeftBeforeRestoreShows = nil
                applyRestore()
            } else {
                snapshotsLeftBeforeRestoreShows = remaining - 1
            }
        }
        if let remaining = snapshotsLeftBeforeReleaseShows {
            if remaining == 0 {
                snapshotsLeftBeforeReleaseShows = nil
                endLease()
                grantAfterRelease()
            } else {
                snapshotsLeftBeforeReleaseShows = remaining - 1
            }
        }
        return SystemSnapshot(
            fans: fans.map(reportedState), sensors: [], activeLease: reportedLease(),
            isThermalEmergencyActive: isThermalEmergencyActive || emergencyHasBegun,
            capturedAt: Date())
    }

    /// The lease a snapshot lists: the authority's, unless a hold is scripted to have lost it.
    private func reportedLease() -> Lease? {
        if let after = leaseHiddenAfterRenewals, renewals >= after { return leaseShownInstead }
        return lease
    }

    private var emergencyHasBegun: Bool {
        emergencyAfterRenewals.map { renewals >= $0 } ?? false
    }

    private func grantAfterRelease() {
        if let holder = takenAfterRelease { grantForeignLease(over: [0], holder: holder) }
    }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        calls.append("acquireLease")
        acquiredRequests.append(request)
        if let acquireRefusal { throw acquireRefusal }
        try AeolusXPCValidation.validate(
            request, enumeratedFanIndices: Set(fans.map(\.index)))
        guard lease == nil else {
            throw AeolusXPCFault.manualControlUnavailable(reason: .leaseHeldByAnotherClient)
        }
        if let pinned = request.fanIndices.compactMap({ pinnedFans[$0] }).first {
            throw AeolusXPCFault.manualControlUnavailable(reason: pinned)
        }
        let granted = Lease(
            holderDescription: request.holderDescription,
            expiresAt: Date().addingTimeInterval(request.timeToLive),
            timeToLive: request.timeToLive)
        lease = granted
        leaseHolder = connection
        leasedFans = Set(request.fanIndices)
        return granted
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        calls.append("renewLease")
        let current = try held(id, by: connection)
        if let limit = renewalsBeforeRefusal, renewals >= limit {
            endLease()
            throw renewalRefusal
        }
        renewals += 1
        if let reclaimAfterRenewals, renewals >= reclaimAfterRenewals {
            for index in leasedFans { reclaim(index) }
        }
        let renewed = Lease(
            id: current.id, holderDescription: current.holderDescription,
            expiresAt: Date().addingTimeInterval(current.timeToLive),
            timeToLive: current.timeToLive)
        lease = renewed
        return renewed
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        calls.append("releaseLease")
        if let releaseRefusal { throw releaseRefusal }
        _ = try held(id, by: connection)
        if snapshotsBeforeReleaseShows > 0 {
            snapshotsLeftBeforeReleaseShows = snapshotsBeforeReleaseShows
        } else {
            endLease()
            grantAfterRelease()
        }
    }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        calls.append("apply")
        _ = try held(leaseID, by: connection)
        if let applyRefusal { throw applyRefusal }
        appliedSettings.append(settings)
        guard !ignoresApply else { return }
        for setting in settings where leasedFans.contains(setting.fanIndex) {
            switch setting.control {
            case .fixed(let rpm):
                let envelope = try envelope(for: setting.fanIndex)
                set(setting.fanIndex, mode: .manualFixed, target: envelope.target(for: rpm).rpm)
            case .automatic, .curve:
                set(setting.fanIndex, mode: .automatic, target: nil)
            }
        }
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        calls.append("restoreAllToAutomatic")
        restoreRequests += 1
        if let restoreRefusal { throw restoreRefusal }
        guard !ignoresRestore else { return }
        if snapshotsBeforeRestoreShows > 0 {
            snapshotsLeftBeforeRestoreShows = snapshotsBeforeRestoreShows
        } else {
            applyRestore()
        }
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {
        calls.append("connectionDidInvalidate")
        if connection == leaseHolder { endLease() }
    }

    // MARK: - Internals

    private func held(_ id: UUID, by connection: ConnectionID) throws -> Lease {
        guard let lease, lease.id == id else { throw AeolusXPCFault.leaseUnknown }
        guard leaseHolder == connection else {
            throw AeolusXPCFault.leaseNotHeldByThisConnection
        }
        return lease
    }

    /// What a restore does once it has landed: every lease dropped, every fan Aeolus can
    /// return returned, and — if scripted — another client in again.
    private func applyRestore() {
        endLease()
        for fan in fans where pinnedFans[fan.index] == nil {
            set(fan.index, mode: .automatic, target: nil)
        }
        if let holder = releasesToAnotherHolder {
            grantForeignLease(over: [0], holder: holder)
        }
    }

    private func endLease() {
        for index in leasedFans where pinnedFans[index] == nil {
            set(index, mode: .automatic, target: nil)
        }
        lease = nil
        leaseHolder = nil
        leasedFans = []
    }

    private func envelope(for index: Int) throws -> FanControlEnvelope {
        guard let fan = fans.first(where: { $0.index == index }) else {
            throw AeolusXPCFault.invalidParameter(name: "fanIndex", detail: "no such fan")
        }
        switch fan.controlEnvelope {
        case .success(let envelope): return envelope
        case .failure(let why):
            throw AeolusXPCFault.boundsImplausible(fanIndex: index, detail: why.description)
        }
    }

    private func reportedState(_ fan: FanState) -> FanState {
        var availability = fan.manualControlAvailability
        if let reason = pinnedFans[fan.index] {
            availability = .unavailable(reason)
        }
        return FanState(
            index: fan.index, firmwareName: fan.firmwareName, actualRPM: fan.actualRPM,
            minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM, targetRPM: fan.targetRPM,
            mode: fan.mode, isReclaimedBySystem: fan.isReclaimedBySystem,
            manualControlAvailability: availability)
    }

    private func set(_ index: Int, mode: FanControlMode, target: Double?) {
        fans = fans.map { fan in
            guard fan.index == index else { return fan }
            return FanState(
                index: fan.index, firmwareName: fan.firmwareName, actualRPM: fan.actualRPM,
                minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM, targetRPM: target,
                mode: mode, isReclaimedBySystem: fan.isReclaimedBySystem,
                manualControlAvailability: fan.manualControlAvailability)
        }
    }

    private func reclaim(_ index: Int) {
        fans = fans.map { fan in
            guard fan.index == index else { return fan }
            return FanState(
                index: fan.index, firmwareName: fan.firmwareName, actualRPM: fan.actualRPM,
                minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM, targetRPM: fan.targetRPM,
                mode: .automatic, isReclaimedBySystem: true,
                manualControlAvailability: .unavailable(.reclaimedBySystem))
        }
    }
}
