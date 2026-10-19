import Foundation
import Testing

/// The engagement's ticket is taken by the driver and by nothing else in the helper (ADR 0014's
/// #410 ticket-and-seal amendment).
///
/// ## Why it is a tripwire
///
/// `beginEngagement(fanAt:)` is synchronous and takes no permit, so `WriteVerbAllowlistTests`
/// does not scan it, and it writes nothing. What makes a stray caller dangerous is not a write but
/// a ticket: one taken anywhere but just before an entitlement refreshes a fan's ticket to the
/// current epoch, or clears an engagement's in-progress record, under an engagement that never
/// asked — so a ticket taken before a machine-wide path ended its lease could be made current after
/// it. So its uses are held to the driver's two sites — the engagement's first statement and the
/// first-step retry — the writer's one-line forward, and the write plane's forward to its ledger,
/// by census. Conformers declare it, and a declaration is not a use. The other edge, a ticket a refused entitlement left behind, is held by
/// the step verb's route: only the driver steps (`EngagementRouteTripwireTests`).
///
/// `SMCFanControlPlane`'s forward to its `PlaneWriteLedger` is the fourth use, through `ledger`
/// (b2; ADR 0014's #410 ticket-and-seal amendment): the plane's own ticket, synchronous and
/// write-free, taken only when the driver takes one through the writer.
///
/// **Mutation:** make `SMCFanControlPlane.beginEngagement(fanAt:)` do nothing. Run: red here, and
/// in `SMCWritePlaneTests.theTicketIsForwardedToTheLedger`.
@Suite("The engagement's ticket is taken only by the driver", .timeLimit(.minutes(1)))
struct EngagementTicketTripwireTests {

    private static let verb = "beginEngagement"

    /// Every use of the ticket verb in `Sources/AeolusHelper` is one of the three allowed, and
    /// every use is one the receiver scan attributes, so no spelling hides one.
    ///
    /// **Mutation:** in `ThermalEmergency`, before § 3's maximum write, add
    /// `writer.beginEngagement(fanAt: fan.index)` — § 3 holds a `SafetyActorWriter`, which forwards
    /// the verb; level 6's `LeaseApplier` holds nothing that can name it. Run: red, at the use
    /// census. **Mutation:** the same call as `[writer][0].beginEngagement(fanAt: fan.index)`. Run:
    /// red, at the escaped-use assertion, and the census stays green: a receiver that is not a word
    /// is attributed to nothing.
    @Test("Only the driver, the writer's forward and the plane's forward take a ticket")
    func onlyTheDriverTakesATicket() throws {
        var uses: [String] = []
        var escaped: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let seen = try SeamScanner.receivers(of: Self.verb, inSource: source)
            uses += seen.map { "\(file.lastPathComponent): \($0)" }
            let named = try SeamScanner.mentions(of: Self.verb, inSource: source)
            if named != seen.count {
                escaped.append("\(file.lastPathComponent): \(named) named, \(seen.count) seen")
            }
        }

        #expect(
            uses.sorted() == [
                "EngagementDriver.swift: writer", "EngagementDriver.swift: writer",
                "SMCFanControlPlane.swift: ledger", "SafetyWriters.swift: plane",
            ],
            """
            an engagement's ticket is taken somewhere other than the driver's two sites, the \
            writer's forward and the plane's forward to its ledger: \(uses.sorted()). A ticket taken anywhere but just before the \
            entitlement can admit a first step after a machine-wide path ended its lease.
            """)
        #expect(
            escaped.isEmpty,
            "a use of `\(Self.verb)` has a receiver the scan cannot read: \(escaped)")
    }
}
