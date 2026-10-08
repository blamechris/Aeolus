import Foundation
import Testing

/// ADR 0012 I1 — "every helper round trip is stamped" — is a property of the source tree. A
/// stamp that brackets *a* call proves nothing about the call a later edit adds beside it, so
/// the property is asserted against the source: exactly one `IOConnectCallStructMethod`
/// exists under `Sources/` and `Tools/`, and it sits inside the closure of a
/// `roundTrips.bracket(.call(…))`. `IOServiceOpen` and `IOServiceClose` anywhere under
/// `Sources/SMCCore` are held to the same rule (`.open`, `.close`), with one exception:
/// `SMCConnection`'s `deinit`. That exemption is for the reason given beside it — the helper
/// never releases its one connection before it exits, so the `deinit` never runs while a
/// watchdog is armed — and not because nothing could read a stamp from it, which is false: the
/// monitor outlives the connection. It is confined to that one file. `Sources/AeolusHelper` is
/// deliberately not scanned for open and close: `SystemPowerObserver` closes the power
/// root-domain connection there, which is not an SMC round trip.
///
/// This is a tripwire, not a proof. It cannot see a call reached through `dlsym`, and it is
/// not trying to; what it catches is the realistic regression — a second call site added "just
/// for this one read", or the call hoisted out of the bracket during a refactor — and it
/// catches that in the build that runs on CI, where no SMC exists to notice.
///
/// ## A scanner is a guard, and is tested as one
///
/// A source scanner that silently stops matching is worse than no scanner: it reports a clean
/// tree. So the matching lives in `StampSiteScanner`, whose tests run it against synthetic
/// sources — including the spellings that would let a site slip past a naive substring match
/// (`call (`, a call split across lines, a comment between the name and its parenthesis, a
/// `//` inside a string literal) — and against the shapes of regression the tripwire exists
/// to catch.
@Suite("Round-trip stamp tripwire", .timeLimit(.minutes(1)))
struct RoundTripStampTripwireTests {

    static let connectionPath = "Sources/SMCCore/SMCConnection.swift"
    static let monitorPath = "Sources/SMCCore/SMCRoundTripMonitor.swift"

    // MARK: - The source tree

    @Test("Exactly one IOConnectCallStructMethod exists, and it is inside bracket(.call(…))")
    func theTreeHasExactlyOneStampedIOConnectCall() throws {
        let files = try StampSiteScanner.treeFiles()
        // Coverage: an enumerator that found nothing would report a clean tree.
        #expect(files.count > 30, "the project's sources were not found")
        #expect(files.contains { $0.path == Self.connectionPath }, "SMCConnection.swift not seen")

        var found: [(path: String, site: StampSiteScanner.Site)] = []
        for file in files {
            for site in StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: file.text) {
                found.append((file.path, site))
            }
        }

        #expect(
            found.count == 1,
            """
            Expected exactly one IOConnectCallStructMethod under Sources/ and Tools/ — ADR \
            0012 I1 stamps the one that exists — found \(found.map(\.path)).
            """)
        for entry in found {
            #expect(
                entry.path == Self.connectionPath,
                "\(entry.path) names IOConnectCallStructMethod; only SMCConnection may")
            #expect(
                StampSiteScanner.isStamped(entry.site, as: ".call("),
                """
                \(entry.path): IOConnectCallStructMethod is not a call inside \
                roundTrips.bracket(.call(…)) { … } — it would be a round trip the watchdog \
                cannot see (\(entry.site)).
                """)
        }
    }

    @Test("No other entry point to a user client exists anywhere in Sources or Tools")
    func noSiblingEntryPointToTheUserClientExists() throws {
        var siblings: [String] = []
        for file in try StampSiteScanner.treeFiles() {
            siblings += StampSiteScanner.siblingEntryPoints(in: file.text).map {
                "\(file.path): \($0)"
            }
        }
        #expect(
            siblings.isEmpty,
            "Another route to a user client, which the round-trip stamp cannot see: \(siblings)"
        )
    }

    @Test(
        "IOServiceOpen and IOServiceClose in SMCCore are stamped, SMCConnection's deinit excepted")
    func openAndCloseAreStamped() throws {
        let core = try StampSiteScanner.treeFiles().filter { $0.path.hasPrefix("Sources/SMCCore/") }
        #expect(core.contains { $0.path == Self.connectionPath }, "SMCConnection.swift not seen")

        for (symbol, operation) in [("IOServiceOpen", ".open"), ("IOServiceClose", ".close")] {
            var found: [(path: String, site: StampSiteScanner.Site)] = []
            for file in core {
                // The destructor exemption is for the connection's own deinit and for no other
                // file: a new type in SMCCore does not inherit it.
                let sites = StampSiteScanner.sites(
                    of: symbol, in: file.text, excludingDeinit: file.path == Self.connectionPath)
                found += sites.map { (file.path, $0) }
            }
            #expect(
                found.count == 1,
                "expected exactly one \(symbol) in Sources/SMCCore outside deinit: \(found)")
            for entry in found {
                #expect(
                    entry.path == Self.connectionPath,
                    "\(entry.path) calls \(symbol); only SMCConnection may")
                #expect(
                    StampSiteScanner.isStamped(entry.site, as: operation),
                    "\(entry.path): \(symbol) is not inside roundTrips.bracket(\(operation))")
            }
        }
    }

    @Test("The monitor declares no public initialiser")
    func theMonitorHasNoPublicInitializer() throws {
        let monitor = try #require(
            try StampSiteScanner.treeFiles().first { $0.path == Self.monitorPath })
        // Coverage: the file does declare initialisers, so an empty result is not an empty scan.
        let normalised = StampSiteScanner.normalise(monitor.text)
        #expect(StampSiteScanner.identifierRanges(of: "init", in: normalised).count >= 2)

        #expect(
            StampSiteScanner.exposedInitializers(in: monitor.text).isEmpty,
            """
            SMCRoundTripMonitor must have no public initialiser: the only public way to a \
            monitor is SMCConnection.roundTrips, so the one a watchdog reads is the one a \
            connection stamps.
            """)
    }
}
