/// What one of `docs/SAFETY.md` § 3's bridge jobs did: the maximum command, and the `.fan(n)`
/// restore after it, **each attempted and each reported**.
///
/// ## One job, one turn per fan
///
/// [ADR 0012](../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)'s
/// 2026-10-18 amendment makes § 3's bridge one plane verb, `FanControlPlane.bridgeThenRestore(_:)`:
/// the command's body and then the restore's, in the turn of § 3's lane that one job takes —
/// three round trips and then at most two, so `WatchdogLimits.writeTurnRoundTrips`. As two verbs
/// it was two turns per fan, and D_cycle's allowance counts one turn in flight ahead of each.
///
/// ## Neither half stops the other
///
/// `ThermalEmergency`'s header gives the asymmetry: a firmware that refuses the maximum write is
/// exactly the machine that most needs the restore attempted, and a restore is the destination
/// whatever the bridge did. So the outcome carries two results and never one throw, and
/// `attempting(maximum:thenRestore:)` is the one place the order and the "whatever the first
/// answered" are written. Both planes run their halves through it.
struct BridgeOutcome: Sendable {

    /// The target put on the wire, or why it was not.
    let maximum: Result<CommandedTarget, any Error>

    /// The `.fan(n)` restore after it, attempted whatever `maximum` is.
    let restore: Result<Void, any Error>

    /// Runs a bridge job's two halves, in order, the second whatever the first answered.
    ///
    /// Synchronous, so a plane runs the whole job inside one turn with nothing suspending between
    /// the halves (ADR 0014's B1 amendment, U15): the command's admission and its writes, then the
    /// restore's plan and its writes. A refused or unanswered command is a `.failure` in the
    /// outcome and no reason to skip the restore.
    static func attempting(
        maximum command: () throws -> CommandedTarget,
        thenRestore restore: () throws -> Void
    ) -> BridgeOutcome {
        let maximum = Result { try command() }
        let restored = Result { try restore() }
        return BridgeOutcome(maximum: maximum, restore: restored)
    }
}
