import Foundation
import Testing

/// `MemberAccessScan`'s parse, checked against fixtures rather than against whatever
/// `Sources` happens to contain today.
///
/// This suite exists because [#236](https://github.com/blamechris/Aeolus/issues/236) is the
/// second time a source-scanning guard in this repository has been narrower than its own claim,
/// and both of that issue's surviving mutations were spellings the tree does not currently
/// contain: an attribute with a space inside its parentheses, and two methods sharing a name.
/// A parser exercised only through the tree it scans is exercised only for the shapes already
/// written there — so the shapes that *would* hide something are exactly the ones nothing runs.
/// `SeamScannerParsingTests` is the same argument about the same tree, and this is its sibling.
@Suite("MemberAccessScan sees the spellings a widening could be written in")
struct MemberAccessScanParsingTests {

    // MARK: - The modifier run

    @Test("An attribute whose argument contains a space does not hide the member")
    func anAttributeWithASpacedArgumentIsSkipped() {
        let fixture = """
            actor Probe {
                @available(macOS 26.0, *) func reopenGate(force flag: Bool) {
                }
            }
            """
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(
            methods.map(\.key) == ["reopenGate(force: Bool)"],
            """
            this is #236's landable mutation: the walk used to drop one whitespace-separated \
            token per `@`, so `@available(macOS` left `26.0,` at the head, `tokens[0]` was \
            never `func`, and an internal synchronous method that sets `hasInvalidated = \
            false` left the population entirely. `swift format lint --strict` accepts this \
            line, so nothing else was going to stop it. Found \(methods.map(\.key)).
            """
        )
        #expect(methods.first?.isPrivate == false)
    }

    @Test("An attribute with no argument, or a balanced one, is still skipped")
    func aPlainAttributeIsSkipped() {
        let fixture = """
            actor Probe {
                @objc private func hidden() {
                }

                @_spi(FanWrite) public func widened() {
                }
            }
            """
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(methods.map(\.key) == ["hidden()", "widened()"])
        #expect(methods.map(\.isPrivate) == [true, false])
    }

    @Test("The modifier run is read in either order, and private(set) is internal")
    func theModifierRunIsReadInEitherOrder() {
        let fixture = """
            actor Probe {
                private(set) var table = LeaseTable()
                static private let clock = 0
                private static var count = 0
                @MainActor var pinned = 0
                fileprivate var scoped = 0
            }
            """
        let properties = MemberAccessScan.members(inSource: fixture, keyword: .property)

        #expect(properties.map(\.name) == ["table", "clock", "count", "pinned", "scoped"])
        #expect(
            properties.map(\.isPrivate) == [false, true, true, false, true],
            """
            `private(set) var table` leaves an internal getter on the state the lease guard \
            exists to keep unreadable, and `static private` is the same declaration as \
            `private static`. Found \(properties.map { "\($0.name):\($0.isPrivate)" }).
            """
        )
    }

    // MARK: - The signature key

    @Test("Two methods sharing a name are two keys")
    func anOverloadIsNotCollapsedOntoItsSibling() {
        let fixture = """
            actor Probe {
                func invalidate() async {
                }

                func invalidate(reopening: Bool) {
                }

                func command(_ rpm: Double, of fan: CommandableFan) {
                }

                func command(_ rpm: Double, of index: Int) {
                }
            }
            """
        let keys = Set(MemberAccessScan.members(inSource: fixture, keyword: .method).map(\.key))

        #expect(
            keys == [
                "invalidate()",
                "invalidate(reopening: Bool)",
                "command(_: Double, of: CommandableFan)",
                "command(_: Double, of: Int)",
            ],
            """
            #236's second mutation is the first pair: `invalidate(reopening:)` sets \
            `hasInvalidated = false` and clears `negotiated`, and under a bare-name key it \
            landed on acknowledged `invalidate` and left 38 tests in 4 suites green. The \
            second pair is the same defect keyed on labels alone, which \
            `SeamScanner.Function.key` records landing once already. Found \(keys.sorted()).
            """
        )
    }

    @Test("A parameter list the formatter wrapped is still read whole")
    func aWrappedParameterListIsParsedAcrossLines() {
        let fixture = """
            extension Probe {
                func acknowledgeRefusal(
                    _ fault: AeolusXPCFault, message: String
                ) -> AcknowledgementReply {
                }

                func acquireLease(
                    _ request: LeaseRequest,
                    from connection: ConnectionID
                ) async throws -> Lease {
                }
            }
            """
        let keys = MemberAccessScan.members(inSource: fixture, keyword: .method).map(\.key)

        #expect(
            keys == [
                "acknowledgeRefusal(_: AeolusXPCFault, message: String)",
                "acquireLease(_: LeaseRequest, from: ConnectionID)",
            ],
            """
            both spellings are in the scanned tree today. A line-local parse would key each \
            of them on an empty clause — `acknowledgeRefusal()` and `acquireLease()` — which \
            is the collapse the key exists to prevent, reintroduced by the parse rather than \
            by the list. Found \(keys).
            """
        )
    }

    @Test("A property's key is its name, because a property cannot be overloaded")
    func aPropertyKeysOnItsName() {
        let fixture = """
            actor Probe {
                var leaseCount: Int { table.count }
            }
            """
        let properties = MemberAccessScan.members(inSource: fixture, keyword: .property)

        #expect(properties.map(\.key) == ["leaseCount"])
        #expect(properties.map(\.name) == properties.map(\.key))
    }

    // MARK: - The indent precondition

    @Test("Only the type's own member indent is scanned")
    func aNestedTypesMembersAreNotTheOuterTypes() {
        let fixture = """
            actor Probe {
                private var hasInvalidated = false

                private struct Nested {
                    var leaked = 0
                    func reopen() {
                    }
                }
            }
            """

        #expect(
            MemberAccessScan.members(inSource: fixture, keyword: .property).map(\.name)
                == ["hasInvalidated"])
        #expect(MemberAccessScan.members(inSource: fixture, keyword: .method).isEmpty)
    }

    @Test("A member written at another indent is invisible here, and the formatter is the gate")
    func anotherIndentIsInvisibleAndTheFormatterCatchesIt() {
        let fixture = """
            actor Probe {
              func reopenGate() {
              }
            }
            """

        #expect(
            MemberAccessScan.members(inSource: fixture, keyword: .method).isEmpty,
            """
            stated rather than implied, because this is the one precondition this scan does \
            not hold: four-space indentation is `.swift-format`'s `indentation` setting, and \
            `swift format lint --recursive --strict Sources` in CI is what rejects this file. \
            A guard whose precondition is held by another gate has to name that gate.
            """
        )
    }

    // MARK: - Resolving a type to its files

    @Test("A type's declaration sites are matched on the whole name, never a prefix")
    func aDeclarationSiteIsMatchedWhole() throws {
        let truncated = try MemberAccessScan.filesDeclaring(
            "HelperConnectionSessio", inTarget: "AeolusHelper")

        #expect(
            truncated.members.isEmpty,
            """
            a prefix match would make `extension HelperConnectionSessionGates` a declaration \
            of `HelperConnectionSession` — and, the direction that hides a widening, would \
            make the file set of a type whose name is a prefix of another's include files \
            that are not its own. Found \(truncated.members).
            """
        )
    }

    @Test("An extension alone puts a file in the member set but not in the declaration set")
    func anExtensionIsAMemberSiteAndNotADeclaration() throws {
        let sites = try MemberAccessScan.filesDeclaring(
            "HelperConnectionSession", inTarget: "AeolusHelper")

        #expect(sites.declarations == ["HelperConnectionSession.swift"])
        #expect(
            sites.members.contains("HelperConnectionSessionGates.swift"),
            "an extension is where a member can be written, which is the whole point of #236")
    }
}
