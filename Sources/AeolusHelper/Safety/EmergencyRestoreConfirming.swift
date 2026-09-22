// The one question the lease core asks `docs/SAFETY.md` § 3, added by
// [#303](https://github.com/blamechris/Aeolus/issues/303). ADR 0011, amendment 2026-09-21.

/// The fans § 3 is keeping because the firmware **accepted** a restore-to-automatic and no read
/// has yet shown the fan automatic.
///
/// Two registers answer it, and it is their union because both reach the same wrong answer
/// the same way. `handbackOwed` holds a fan a lease teardown's restore handed back (#295);
/// `restoredUnconfirmed` holds one § 3 bridged and restored itself (#300). Either kind reads
/// manual under no live lease and matches no lease-core register, so until #303 both the grant
/// path and the snapshot called it `.foreignManualControl` — blaming another program for a
/// write Aeolus issued and the firmware took. Such a fan observed in manual is refused
/// `.restoreToAutomaticUnconfirmed` instead.
///
/// ## A role, so the lease core cannot reach § 3's mutators
///
/// The same narrowing `ForeignManualControlSensing` gives `StartupReconciliation`: the
/// conformer is an actor with mutators, and the existential is what hides them. `LeaseAuthority`
/// holds this, never `ThermalEmergency`, for the reason it holds `ThermalEmergencyLatch` and not
/// § 3 itself.
///
/// ## Not a fourth union into `fansAeolusIsAccountableFor`
///
/// That set is an **exemption**: both consumers skip a fan in it, and the lease core's own
/// registers then match it against nothing — so a union would report the fan available and
/// grant the lease. This set reclassifies the refusal at the same step; it never lifts it.
/// handback-ledger.md § *"What the snapshot is told"*.
///
/// ## A stored read, and it must stay one
///
/// The conformance reads two dictionaries' keys and awaits nothing. § 3 is reentrant across
/// every `await` in `cycle()`, so this read interleaves with a cycle rather than queueing behind
/// it. Made a method that reads the firmware, it would hold every grant and every snapshot
/// behind § 3's 1 Hz reads.
protocol EmergencyRestoreConfirming: Sendable {
    var fansAwaitingRestoreConfirmation: Set<Int> { get async }
}

extension ThermalEmergency: EmergencyRestoreConfirming {
    var fansAwaitingRestoreConfirmation: Set<Int> {
        fansOwedHandbackReadBack.union(fansRestoredUnconfirmed)
    }
}
