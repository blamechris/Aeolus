import SMCCore

/// The one thing the snapshot path needs to know about a fan that enumeration cannot tell
/// it: **who currently owns the fan**, read from `F<n>Md`.
///
/// ## Why a protocol of its own, and this narrow
///
/// `FanStateSensing` already answers this, and refines this protocol so every E5 conformer
/// answers it for free — hand `ReadOnlyFanAuthority` an `SMCFanControlPlane` and it is
/// already a `FanModeSensing`. The reason the snapshot path takes the *narrow* seam anyway
/// is scheduling, and it is the same argument `SnapshotSensorReads` makes in the other
/// direction.
///
/// `SMCFanControlPlane` issues every read it makes at `.supervisor`, because everything that
/// holds one is a safety mechanism whose lateness is blindness. A snapshot read issued at
/// that priority would put a client's 1 Hz reporting in the queue § 3's cycle is meant to
/// have to itself, and [#134](https://github.com/blamechris/Aeolus/issues/134) records that
/// the count of outstanding supervisor reads is precisely the number
/// `SMCReadScheduler`'s starvation arithmetic is sensitive to. So the snapshot reads `F<n>Md`
/// through `SnapshotFanModeReads` below, at `.snapshot`, alongside the reads it already
/// makes — and [#103](https://github.com/blamechris/Aeolus/issues/103), which composes the
/// supervisor, can pass its control plane here instead without changing this signature.
///
/// One verb, one key, no write side. A snapshot is a report; nothing reachable from here may
/// command a fan, and the narrowness is what makes that true by construction rather than by
/// review.
protocol FanModeSensing: Sendable {

    /// Reads `F<n>Md`: whether the system's thermal management owns this fan, or something
    /// else does.
    ///
    /// - Throws: when the answer is not known. **Never a default**, for the reason
    ///   `FanControlState.mode` is not optional: there is no safe value to stand in for an
    ///   unread mode, and "assume automatic" is exactly the claim `CLAUDE.md` rule 6 forbids
    ///   a caller from making on the machine's behalf.
    func readMode(ofFan index: Int) async throws -> FirmwareFanMode
}

extension FanStateSensing {

    /// The mode out of the control state E5 already reads, so the safety seam satisfies the
    /// snapshot's narrower one without a second read verb or a second decode.
    func readMode(ofFan index: Int) async throws -> FirmwareFanMode {
        try await readControlState(ofFan: index).mode
    }
}

// MARK: - The snapshot path's conformer

/// Reads `F<n>Md` through the provider every other snapshot read already goes through, and
/// therefore at the snapshot's own priority.
///
/// A `SensorProvider` carries no priority in its signature, which is why this type takes the
/// one the authority was given rather than a scheduler it could name a priority on: whatever
/// the composition root wired the snapshot to read through — `SMCReadScheduler.snapshotReader`
/// in the helper, a double in a test — is what this reads through too. There is deliberately
/// no way to build one over a different source from the fans beside it, because a snapshot
/// whose mode came from one connection and whose RPM came from another is one instant's
/// report assembled from two.
///
/// One key per fan, one subset read per fan. On a machine with one or two fans that is one
/// or two extra turns against the 48 a full snapshot already takes; the alternative — one
/// batched read of every fan's mode key — would make this seam something `FanStateSensing`
/// could no longer satisfy, and the composability is worth more than 2% of a turn budget.
struct SnapshotFanModeReads: FanModeSensing {

    private let provider: any SensorProvider

    init(provider: some SensorProvider) {
        self.provider = provider
    }

    func readMode(ofFan index: Int) async throws -> FirmwareFanMode {
        guard let key = SMCKey.fanMode(index) else {
            throw FanControlPlaneError.fanNotAddressable(index: index)
        }

        let outcomes = try await provider.read(keys: [key.rawValue])
        guard let outcome = outcomes.first, outcome.key == key.rawValue else {
            throw FanControlPlaneError.readFailed(detail: "\(key) produced no outcome")
        }

        switch outcome.result {
        case .failure(let failure):
            throw FanControlPlaneError.readFailed(detail: "\(key): \(failure)")
        case .success(let reading):
            // The seam's finiteness rule, not a second copy of it: a byte-swapped decode
            // reaching a mode comparison would answer `.manual` for `NaN` on the strength of
            // `NaN != 0`, which is a fan reported as held by nobody's decision.
            switch FanControlPlaneValue.finite(reading.value, describing: "\(key)") {
            case .failure(let error): throw error
            case .success(let value): return FirmwareFanMode(declaredByFirmware: value)
            }
        }
    }
}

// MARK: - The decode

extension FirmwareFanMode {

    /// `F<n>Md` is a flag key: zero is the system's thermal management, and **anything else
    /// is manual.**
    ///
    /// Not rounded, and that is the load-bearing part. A value of `0.4` — a decode artefact
    /// rather than anything firmware would intend — reads as manual here, and would read as
    /// automatic if this rounded first. The asymmetry decides it: reading a manual fan as
    /// automatic leaves it pinned with reconciliation satisfied that there is nothing to do,
    /// which is exactly the failure E5 exists to prevent. Reading an automatic fan as manual
    /// costs one redundant restore write to a fan that is already automatic.
    ///
    /// Here rather than inside `SMCFanControlPlane`, where it used to be private, because
    /// the snapshot path now decodes the same key: two spellings of this rule would be two
    /// answers to "is this fan on automatic control", and the supervisor and the client would
    /// eventually disagree about the same fan.
    init(declaredByFirmware value: Double) {
        self = value == 0 ? .automatic : .manual
    }
}
