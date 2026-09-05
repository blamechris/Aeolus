/// The one-way gate the orderly teardown closes before it hands the fans back.
///
/// ## What it is for
///
/// `SignalTeardown` releases every lease and then restores every fan. Between those two
/// steps, and after them, the Mach service is still advertised: `NSXPCListener` is resumed
/// for the life of the process and nothing in `Sources/` un-advertises it. A client that
/// acquired a lease in that window would hold fans a process on its way out has already
/// stopped counting a TTL for — [#103](https://github.com/blamechris/Aeolus/issues/103)'s
/// decision A4 names closing that window as the *first* step of the teardown, before the
/// release, for exactly that reason.
///
/// ## One-way, and that is the whole of its state
///
/// It opens once, at construction, and closes once. There is no reopen and there must not
/// be one: a gate that could be reopened is a gate an XPC message could reopen, and
/// `CLAUDE.md`'s rule 5 — *there is no XPC message that disables a safety mechanism, and
/// none may be added* — covers this as much as it covers a ceiling. Monotonicity is also
/// what makes the read below safe to race: the only stale answer this gate can give is
/// "open" when it has just closed, and never "closed" when it has not.
///
/// ## It covers arrival, not flight
///
/// `HelperConnectionSession`'s own teardown gate says the same thing about the same shape,
/// and the reasoning transfers verbatim: `SupervisedFanAuthority` reads this before it
/// suspends into the lease core, so a verb that has not *started* when the gate closes is
/// refused, and one already mid-`await` is not. What covers flight is the step after it —
/// the unconditional `restoreToAutomatic(.everyFan)`, which puts back every fan whatever
/// was granted in the gap. Calling this defence in depth rather than a guarantee is the
/// honest description; a gate advertised as a guarantee would be `CLAUDE.md` rule 6 applied
/// to a safety mechanism's own documentation.
///
/// ## Why an actor
///
/// The daemon has no lock-shaped answer available: `Synchronization.Mutex` needs macOS 15
/// and this package's floor is 13, and an unchecked conformance over an `NSLock` is banned
/// in `Sources/AeolusHelper` by rule 10 and by the `no_unchecked_sendable_in_helper` lint.
/// An actor is what is left, it costs one hop on a path that is already `async`, and
/// `ThermalEmergencyLatch` reaches for it for the same reason one screen up.
actor ControlMessageGate {

    /// `true` once the teardown has begun. Never returns to `false`.
    private(set) var isClosed = false

    /// Refuses every control verb from here on. Idempotent, because a second signal is an
    /// ordinary thing for a dying daemon to receive.
    func close() {
        isClosed = true
    }
}
