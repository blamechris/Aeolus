import AeolusXPC

/// One read of the machine: the snapshot the read path reports, and what `F<n>Md` answered for
/// each fan on that same read ([#360](https://github.com/blamechris/Aeolus/issues/360)).
///
/// The snapshot cannot carry the second half itself. `FanState.mode` folds a mode that did not
/// read into `.automatic` (#178), because the wire has no way yet to say "not known", so a fan
/// that answered automatic and a fan that answered nothing are the same value there. Step 5 of the
/// availability ladder has to tell them apart, as `StartupReconciliation.refusalForGrant` does
/// for its own fresh read: the second is refused `.supervisorBlind`.
///
/// One value rather than a second read of the key. Two reads could answer differently, and the
/// availability would then be judged from a read the reported fan was not built from.
struct MachineObservation: Sendable {

    /// What `ReadOnlyFanAuthority.snapshot()` reports.
    let snapshot: SystemSnapshot

    /// `F<n>Md` for every fan whose mode read on this snapshot. **A fan absent from it did not
    /// read**: absence is the answer, never a default.
    let modes: [Int: FirmwareFanMode]
}
