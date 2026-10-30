import Foundation
import Testing

/// What `MemberAccessScan` records of a declaration beyond its name and whether it is private:
/// the spelling an acknowledged list pins, and the modifier-only lines above a declaration that
/// belong to it ([#604](https://github.com/blamechris/Aeolus/issues/604)).
///
/// Fixtures rather than the tree, for the reason `MemberAccessScanParsingTests` gives: no member
/// in `Sources` has a modifier on a line of its own, so the tree cannot exercise a parse of it,
/// and a parse nothing exercises is one whose misses are invisible.
@Suite("MemberAccessScan reads a declaration as spelled, modifiers above it included")
struct MemberAccessScanSpellingTests {

    @Test("A member's spelling is its modifier run in source order, the introducer, and its key")
    func aSpellingKeepsEveryModifierItWasWrittenWith() {
        let fixture = """
            actor Probe {
                public var shown: Int { 0 }
                private(set) var counter: UInt64 = 0
                nonisolated public func updates() {
                }

                @available(macOS 26.0, *) func gated(force flag: Bool) {
                }

                func plain(_ value: Int) {
                }

                internal func written(id: UUID) {
                }
            }
            """
        let properties = MemberAccessScan.members(inSource: fixture, keyword: .property)
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(properties.map(\.spelling) == ["public var shown", "private(set) var counter"])
        #expect(
            methods.map(\.spelling) == [
                "nonisolated public func updates()",
                "@available(macOS 26.0, *) func gated(force: Bool)",
                "func plain(_: Int)",
                "internal func written(id: UUID)",
            ],
            """
            #604: an acknowledged list keyed on the name alone could not tell `func renewLease` \
            from `public func renewLease`, so a member already acknowledged as internal could be \
            made public with every access test green. `internal` written out is a different \
            spelling from none, deliberately: it has to be re-stated. Found \
            \(methods.map(\.spelling)).
            """
        )
    }

    @Test("A property's name is the last word of its spelling")
    func aPropertysNameIsTheLastWordOfItsSpelling() {
        let fixture = """
            actor Probe {
                nonisolated(unsafe)
                private(set) var counter: UInt64 = 0
                @available(macOS 26.0, *) nonisolated var gated: Int { 0 }
                let plain = 0
            }
            """
        let properties = MemberAccessScan.members(inSource: fixture, keyword: .property)

        #expect(
            properties.map { MemberAccessScan.name(ofPropertySpelling: $0.spelling) }
                == ["counter", "gated", "plain"],
            """
            #607: the checks that read an acknowledged property's accessor block take its name, \
            and the lists they read hold spellings. The name is the key, which is what a \
            spelling ends in. Found \(properties.map(\.spelling)).
            """
        )
    }

    @Test("A modifier alone on the line above is part of the member it precedes")
    func aModifierOnTheLineAboveJoinsItsDeclaration() {
        let fixture = """
            actor Probe {
                nonisolated(unsafe)
                private(set) var counter: UInt64 = 0

                public

                // why the next line is public
                func widened() {
                }

                private
                var hidden = 0
            }
            """
        let properties = MemberAccessScan.members(inSource: fixture, keyword: .property)
        let methods = MemberAccessScan.members(inSource: fixture, keyword: .method)

        #expect(
            properties.map(\.spelling) == [
                "nonisolated(unsafe) private(set) var counter",
                "private var hidden",
            ])
        #expect(properties.map(\.isPrivate) == [false, true])
        #expect(
            methods.map(\.spelling) == ["public func widened()"],
            """
            #604's second item: the scan read the line a declaration is on and never the one \
            above it, so `nonisolated(unsafe)` over `private(set) var counter`, or `public` \
            over `func widened()`, left the member spelled as it was before. A blank line or a \
            comment between a modifier and its declaration is legal Swift and joins them all \
            the same. Found \(methods.map(\.spelling)).
            """
        )
    }

    @Test("Only modifiers join a declaration, and a trailing comment is not a modifier")
    func onlyModifiersJoinADeclarationAndACommentIsCut() {
        let fixture = """
            actor Probe {
                public
                var previous = 0
                func inherited() {
                }
                nonisolated  // not a modifier of anything below
                var counter = 0
            }
            """
        let properties = MemberAccessScan.members(inSource: fixture, keyword: .property)

        #expect(
            properties.map(\.spelling) == ["public var previous", "nonisolated var counter"],
            """
            `public` belongs to `var previous` and stops there: the line above `var counter` is \
            a `}`, which ends the run, so it does not reach back past a declaration and a body \
            to a modifier that is not its own. `nonisolated` with a comment after it is still a \
            modifier line, because a comment must not be what hides a modifier from the \
            declaration beneath it. Found \(properties.map(\.spelling)).
            """
        )
    }

    @Test("The judged declaration of a named member includes the modifiers above it")
    func theJudgedDeclarationIncludesTheModifierLinesAbove() throws {
        let code = """
            actor Probe {
                private var other = 0

                nonisolated(unsafe)
                // note
                private(set) var counter: UInt64 = 0
                private(set) var bare: UInt64 = 0  // trailing
            }
            """
        let counter = try MemberAccessScan.declaration(
            of: "var counter: UInt64 = 0", in: code, from: "Probe.swift")
        let bare = try MemberAccessScan.declaration(
            of: "var bare: UInt64 = 0", in: code, from: "Probe.swift")
        let other = try MemberAccessScan.declaration(
            of: "var other = 0", in: code, from: "Probe.swift")

        #expect(counter == "nonisolated(unsafe) private(set) var counter: UInt64 = 0")
        #expect(other == "private var other = 0")
        #expect(
            bare == "private(set) var bare: UInt64 = 0  // trailing",
            """
            a trailing comment stays on the line: only whole-line comments are stripped. That \
            fails closed against an exact comparison, and the guard's message says to keep the \
            declaration bare. Found \(bare).
            """
        )
    }

    @Test("A two-line modifier declaration in the formatter's spelling is not a member here")
    func theFormatterSpellingOfATwoLineDeclarationIsNotInThePopulation() {
        let fixture = """
            actor Probe {
                nonisolated(unsafe)
                    private(set) var counter: UInt64 = 0

                public
                    func widened() {
                    }
            }
            """

        #expect(
            MemberAccessScan.members(inSource: fixture, keyword: .property).isEmpty
                && MemberAccessScan.members(inSource: fixture, keyword: .method).isEmpty,
            """
            #605 inverts this. It is stated rather than implied, because it is a hole and `swift \
            format lint --strict` is not the gate for it: the formatter writes the second line of \
            a broken declaration at eight spaces, which `members(inSource:keyword:)` reads as a \
            nested member and skips. A member written this way, new or an existing one widened \
            in it, is in no population; an acknowledged one goes missing and its list fails.
            """
        )
    }

    @Test("An extension's header carries its modifier and the lines above it, its type whole")
    func anExtensionHeaderIsReadWithItsModifiers() throws {
        let code = """
            public extension Probe {
                func widened() {
                }
            }

            @MainActor
            public
            extension Probe where Self: Sendable {
            }

            extension Probe {
            }

            extension ProbeGates {
            }
            """

        #expect(
            try MemberAccessScan.extensionHeaders(of: "Probe", inSource: code) == [
                "public extension Probe {",
                "@MainActor public extension Probe where Self: Sendable {",
                "extension Probe {",
            ],
            """
            #604: `public extension Probe` is `public` for `widened()` and appears on its line \
            nowhere, so the header is what has to be read; a modifier alone on the line above is \
            part of it, and `ProbeGates` is another type.
            """
        )
    }
}
