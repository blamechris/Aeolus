import Foundation
import Testing

/// `StampSiteScanner` against synthetic sources. A source scanner that silently stops matching
/// reports a clean tree, so every branch of it that exists to stop code being hidden has a
/// source here that it must still see, and every branch that exists to ignore text (comments,
/// mentions) has a source it must ignore. `RoundTripStampTripwireTests` runs the same scanner
/// over the real tree.
@Suite("Stamp-site scanner, against synthetic sources", .timeLimit(.minutes(1)))
struct StampSiteScannerTests {

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
        // The operation still starts with `.call(`, so the *only* thing wrong is where the use
        // sits. A source that also had the wrong operation would be refused for that reason and
        // never exercise the argument-versus-body rule at all.
        let source = """
            roundTrips.bracket(.call(key: IOConnectCallStructMethod(a), selector: 5)) { }
            """
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

    @Test("A call in nested brackets is judged by the innermost bracket, whichever way round")
    func aNestedBracketIsJudgedByTheInnermost() {
        let callInsideOpen = """
            roundTrips.bracket(.call(key: key, selector: selector)) {
                roundTrips.bracket(.open) {
                    IOConnectCallStructMethod(a)
                }
            }
            """
        let sites = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: callInsideOpen)
        #expect(sites.count == 1)
        #expect(!StampSiteScanner.isStamped(sites[0], as: ".call("), "an outer .call( vouched")

        let openInsideCall = """
            roundTrips.bracket(.open) {
                roundTrips.bracket(.call(key: key, selector: selector)) {
                    IOConnectCallStructMethod(a)
                }
            }
            """
        let inner = StampSiteScanner.sites(of: "IOConnectCallStructMethod", in: openInsideCall)
        #expect(inner.count == 1)
        #expect(StampSiteScanner.isStamped(inner[0], as: ".call("), "an outer .open condemned")
    }

    @Test("A bare reference to the symbol is a site that is not a call")
    func anAliasIsNotACall() {
        // Inside a correct bracket, so the only thing wrong is that nothing is called here: the
        // alias is invoked somewhere the scan cannot follow it.
        let source = """
            roundTrips.bracket(.call(key: key, selector: selector)) {
                let route = IOConnectCallStructMethod
                return route(a, 2, i, 80, o, &n)
            }
            """
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
            // An escaped quote does not end the string, so the `//` after it is still inside
            // the literal and does not hide the call that follows on the line.
            "let s = \"\\\"// \"; IOConnectCallStructMethod(a)",
            // A multi-line literal is one string: the unterminated-looking `/*` inside it does
            // not open a comment that swallows the call after the literal.
            "let doc = \"\"\"\nsee /* here\n\"\"\"\nIOConnectCallStructMethod(a)",
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
            IOConnectSetCFProperties(a, b)
            IOConnectSetCFProperty(a, b, c)
            IOConnectMapMemory64(a, b, c, d, e, f)
            IOConnectAddClient(a, b)
            IOConnectSetNotificationPort(a, b, c, d)
            // IOConnectCallAsyncMethod(a)
            """
        #expect(
            StampSiteScanner.siblingEntryPoints(in: source) == [
                "IOConnectCallMethod", "IOConnectCallScalarMethod", "IOConnectTrap6",
                "IOConnectSetCFProperties", "IOConnectSetCFProperty", "IOConnectMapMemory64",
                "IOConnectAddClient", "IOConnectSetNotificationPort",
            ])
    }

    @Test(
        "An initialiser that is public, package or open is found; an internal one is not",
        arguments: [
            ("public convenience init() {}", 1),
            ("@_spi(Anything) public init(a: Int) {}", 1),
            ("package init() {}", 1),
            ("open required  init() {}", 1),
            ("public\n    init() {}", 1),
            ("convenience init() {}", 0),
            ("init<C: Clock>(clock: C) where C.Instant == Instant {}", 0),
            ("// public init() {}", 0),
            ("/// public convenience init() {}", 0),
        ])
    func exposedInitializersAreFound(_ source: String, _ expected: Int) {
        #expect(StampSiteScanner.exposedInitializers(in: source).count == expected, "\(source)")
    }
}
