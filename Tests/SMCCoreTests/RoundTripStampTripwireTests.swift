import Foundation
import Testing

/// ADR 0012 I1 — "every helper round trip is stamped" — is a property of the source tree. A
/// stamp that brackets *a* call proves nothing about the call a later edit adds beside it, so
/// the property is asserted against the source: exactly one `IOConnectCallStructMethod`
/// exists under `Sources/` and `Tools/`, and it sits inside the closure of a
/// `roundTrips.bracket(.call(…))`. `IOServiceOpen` and `IOServiceClose` in `SMCConnection`
/// are held to the same rule (`.open`, `.close`), except in `deinit`, which nothing can read
/// a stamp from.
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
@Suite("Round-trip stamp tripwire")
struct RoundTripStampTripwireTests {

    static let connectionPath = "Sources/SMCCore/SMCConnection.swift"

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

    @Test("No sibling IOConnectCall or IOConnectTrap entry point exists anywhere")
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

    @Test("IOServiceOpen and IOServiceClose in SMCConnection are stamped, deinit excepted")
    func openAndCloseAreStamped() throws {
        let connection = try #require(
            try StampSiteScanner.treeFiles().first { $0.path == Self.connectionPath })

        for (symbol, operation) in [("IOServiceOpen", ".open"), ("IOServiceClose", ".close")] {
            let sites = StampSiteScanner.sites(
                of: symbol, in: connection.text, excludingDeinit: true)
            #expect(sites.count == 1, "expected exactly one \(symbol) outside deinit: \(sites)")
            for site in sites {
                #expect(
                    StampSiteScanner.isStamped(site, as: operation),
                    "\(symbol) is not a call inside roundTrips.bracket(\(operation)) { … }: \(site)"
                )
            }
        }
    }

    // MARK: - The scanner, against synthetic sources

    /// A well-formed connection, as a baseline every mutation below departs from by one edit.
    private static let wellFormed = """
        actor Connection {
            deinit { IOServiceClose(connection) }
            func open() {
                let r = roundTrips.bracket(.open) { IOServiceOpen(a, b, 0, &c) }
            }
            func close() {
                roundTrips.bracket(.close) { IOServiceClose(connection) }
            }
            func call() {
                let k = roundTrips.bracket(.call(key: key, selector: selector)) {
                    IOConnectCallStructMethod(connection, 2, i, 80, o, &n)
                }
            }
        }
        """

    @Test("The well-formed shape passes, so the failures below are caused by their one edit")
    func theBaselineIsClean() {
        let call = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: Self.wellFormed)
        #expect(call.count == 1)
        #expect(call.allSatisfy { StampSiteScanner.isStamped($0, as: ".call(") })

        let open = StampSiteScanner.sites(
            of: "IOServiceOpen", in: Self.wellFormed, excludingDeinit: true)
        #expect(open.count == 1)
        #expect(open.allSatisfy { StampSiteScanner.isStamped($0, as: ".open") })

        let close = StampSiteScanner.sites(
            of: "IOServiceClose", in: Self.wellFormed, excludingDeinit: true)
        #expect(close.count == 1, "the deinit's IOServiceClose is exempt, the close()'s is not")
        #expect(close.allSatisfy { StampSiteScanner.isStamped($0, as: ".close") })

        // Without the exemption the deinit's call is a second, unstamped site — which is the
        // exemption doing its job, and proves it removes `deinit` and nothing else.
        let unexempt = StampSiteScanner.sites(of: "IOServiceClose", in: Self.wellFormed)
        #expect(unexempt.count == 2)
    }

    @Test("A second call site is counted")
    func aSecondCallSiteIsSeen() {
        let source =
            Self.wellFormed + "\nfunc extra() { IOConnectCallStructMethod(a, 2, i, 80, o, &n) }"
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 2)
        #expect(sites.filter { !StampSiteScanner.isStamped($0, as: ".call(") }.count == 1)
    }

    @Test("A call hoisted out of its bracket is not stamped")
    func aHoistedCallIsNotStamped() {
        let source = """
            func call() {
                let r = IOConnectCallStructMethod(connection, 2, i, 80, o, &n)
                roundTrips.bracket(.call(key: key, selector: selector)) { r }
            }
            """
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 1)
        #expect(!StampSiteScanner.isStamped(sites[0], as: ".call("))
    }

    @Test("A call passed as the bracket's argument rather than run in its closure is not stamped")
    func aCallInTheArgumentListIsNotStamped() {
        let source = "roundTrips.bracket(IOConnectCallStructMethod(a, 2, i, 80, o, &n)) { }"
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 1)
        #expect(!StampSiteScanner.isStamped(sites[0], as: ".call("))
    }

    @Test("A call under the wrong operation is not stamped as that operation")
    func aCallUnderTheWrongOperationIsNotStamped() {
        let source = "roundTrips.bracket(.open) { IOConnectCallStructMethod(a, 2, i, 80, o, &n) }"
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 1)
        #expect(!StampSiteScanner.isStamped(sites[0], as: ".call("))
    }

    @Test("A bare reference to the symbol is a site that is not a call")
    func anAliasIsNotACall() {
        let source = "let route = IOConnectCallStructMethod\nroute(a, 2, i, 80, o, &n)"
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 1)
        #expect(!sites[0].isCall)
        #expect(!StampSiteScanner.isStamped(sites[0], as: ".call("))
    }

    @Test(
        "Spelling a call differently does not hide it",
        arguments: [
            "IOConnectCallStructMethod (a)",
            "IOConnectCallStructMethod\n    (a)",
            "IOConnectCallStructMethod /* hidden */ (a)",
            "IOConnectCallStructMethod/**/(a)",
            "IOConnectCallStructMethod // trailing comment\n(a)",
            "let u = \"http://example.invalid\"; IOConnectCallStructMethod(a)",
            "try IOConnectCallStructMethod(a)",
        ])
    func aRespelledCallIsStillACall(_ source: String) {
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 1, "lost the call in: \(source)")
        #expect(sites.first?.isCall == true, "no longer a call in: \(source)")
    }

    @Test("A receiver and operation split across lines are still recognised as a bracket")
    func aSplitBracketIsRecognised() {
        let source = """
            roundTrips
                .bracket(
                    .call(key: key, selector: selector)
                ) {
                    IOConnectCallStructMethod(a)
                }
            """
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source)
        #expect(sites.count == 1)
        #expect(sites.allSatisfy { StampSiteScanner.isStamped($0, as: ".call(") })
    }

    @Test(
        "Mentions in comments are not sites",
        arguments: [
            "// IOConnectCallStructMethod(a)",
            "/// IOConnectCallStructMethod(a)",
            "/* IOConnectCallStructMethod(a) */",
            "/* a /* IOConnectCallStructMethod(a) */ b IOConnectCallStructMethod(a) */",
            "let x = 1 // IOConnectCallStructMethod(a)",
        ])
    func commentedMentionsAreNotSites(_ source: String) {
        #expect(StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: source).isEmpty)
    }

    @Test("A longer identifier containing the symbol is not the symbol")
    func aLongerIdentifierIsNotASite() {
        #expect(
            StampSiteScanner.sites(
                of: "IOServiceClose", in: "myIOServiceClose(a) IOServiceClosed(a)"
            )
            .isEmpty)
    }

    @Test("Sibling entry points to a user client are found, the stamped one is not a sibling")
    func siblingsAreFound() {
        let source = """
            IOConnectCallStructMethod(a)
            IOConnectCallMethod(a)
            IOConnectCallScalarMethod (a)
            IOConnectTrap6(a)
            // IOConnectCallAsyncMethod(a)
            """
        #expect(
            StampSiteScanner.siblingEntryPoints(in: source)
                == ["IOConnectCallMethod", "IOConnectCallScalarMethod", "IOConnectTrap6"])
    }
}
