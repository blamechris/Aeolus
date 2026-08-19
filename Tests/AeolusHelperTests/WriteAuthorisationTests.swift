import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The write seam's authorisation, and the tripwires that keep its signatures honest.
///
/// [#108](https://github.com/blamechris/Aeolus/issues/108) asked for the seam to take a
/// clamped target rather than a `Double`. That alone turned out to be half a control:
/// `FanTargetRPM` proves a clamp happened but carries no fan identity, so a target clamped
/// through fan 0's envelope could still be commanded to fan 1 whose declared maximum was
/// lower, and a fan whose bounds the plausibility gate refused could be written through any
/// other fan's envelope — the exact invariant `docs/SAFETY.md` §2 states absolutely.
/// [ADR 0008](../../docs/ADR/0008-write-authorisation.md) closes it by stamping the permit
/// from the plane's own read.
///
/// The suite is deliberately thin on clamp arithmetic. `Tests/FanKitTests/FanClampTests`
/// already owns that and kills the same mutants, and re-asserting it through a mock that
/// echoes it would be evidence for code this seam does not contain. What is tested here is
/// what is new: the binding, the refusal, and the shape of the signatures that deliver them.
@Suite("The write seam's authorisation")
struct WriteAuthorisationTests {

    // MARK: - A fan whose bounds were refused cannot be written at all

    /// `docs/SAFETY.md` §2: *"no target write of any kind may be produced for it, ever …
    /// the only action such a fan is subject to is the bounds-free mode verb,
    /// restore-to-automatic."*
    ///
    /// That sentence used to be false in two ways at once — a target reached such a fan
    /// through any other fan's envelope, and `engageManualControl(ofFan:)` took a bare index
    /// and was gated by nothing whatsoever. Now there is no permit, and neither write verb
    /// has an overload that accepts an index, so there is no call left to make.
    ///
    /// Checked across every shape of implausible declaration the gate refuses, so that a gate
    /// narrowed to one case cannot quietly re-open the others.
    @Test(
        "A fan whose declared bounds fail the gate is refused a permit",
        arguments: [
            ScriptedControlPlane.FanCondition.invertedBounds,
            ScriptedControlPlane.FanCondition.undecodableBounds,
            ScriptedControlPlane.FanCondition(minimumRPM: 10, maximumRPM: 40),
            ScriptedControlPlane.FanCondition(minimumRPM: 1_350, maximumRPM: 90_000),
            ScriptedControlPlane.FanCondition(minimumRPM: -500, maximumRPM: 5_777),
        ])
    func anImplausibleDeclarationIsRefusedAPermit(
        condition: ScriptedControlPlane.FanCondition
    ) {
        #expect(throws: FanBoundsImplausibility.self) {
            try commandableFan(0, declaring: condition)
        }
    }

    /// The converse, so the test above cannot pass by refusing everything.
    ///
    /// A declared minimum of zero is legitimate — `docs/RECOVERY.md` records fans stopping at
    /// idle as normal on many Macs — and must be granted a permit rather than refused, since
    /// refusing it would deny manual control on real hardware. What keeps `CLAUDE.md` rule 3
    /// true for such a fan is the floor, asserted below.
    @Test("A fan declaring a minimum of zero is granted a permit, not refused")
    func aZeroMinimumFanIsStillCommandable() throws {
        let fan = try commandableFan(0, declaring: .zeroMinimum)

        #expect(fan.index == 0)
        #expect(fan.envelope.lowestCommandableRPM == FanSafetyLimits.minimumManualRPM)
    }

    // MARK: - The permit is stamped by the read

    /// The property the whole of ADR 0008 exists for: the index the seam writes to comes out
    /// of the same value as the bounds it clamped into, so the two cannot disagree.
    ///
    /// Commanding is expressed against a permit alone. There is no second parameter to pass a
    /// different fan through, which is why the cross-fan mistake is *absent* from this file
    /// rather than tested in it — that call does not compile. What is asserted here is the
    /// half that still could go wrong: that the stamp carries the index the read produced.
    @Test("A permit read for one fan commands that fan, clamped into that fan's bounds")
    func aPermitCommandsTheFanItWasReadFor() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .init(minimumRPM: 1_000, maximumRPM: 2_000)],
            stages: [.nominal()])

        let fan = try await plane.readEnvelope(ofFan: 1).commandable.get()
        let target = fan.target(for: 4_200)

        #expect(fan.index == 1)
        #expect(target.fanIndex == 1)

        // 4200 is a legal speed for fan 0 and is far above fan 1's declared maximum. Clamped
        // into fan 1's range is the whole claim; clamped into fan 0's would be the defect.
        #expect(target.rpm == 2_000)

        let commanded = try await plane.commandTarget(target)
        #expect(commanded == CommandedTarget(fanIndex: 1, rpm: 2_000))

        // Fan 0 was never touched — the half that an index-equality assertion alone misses.
        let untouched = try await plane.readControlState(ofFan: 0)
        #expect(untouched.target == .rpm(1_800))
    }

    /// `CLAUDE.md` rule 3 at the last hop before firmware, asserted on what the seam was
    /// actually handed rather than on a return value alone.
    ///
    /// This is the one clamp assertion the suite keeps, because it is the only one that
    /// reaches through the seam: commanding zero on a fan whose firmware declares a minimum
    /// of zero must arrive as `minimumManualRPM`, and the permit is what makes that
    /// unskippable rather than merely conventional.
    @Test("Commanding zero on a fan declaring a zero minimum writes the floor, never zero")
    func zeroIsFlooredBeforeItReachesTheFirmware() async throws {
        let plane = ScriptedControlPlane(fans: [0: .zeroMinimum], stages: [.nominal()])
        let fan = try commandableFan(0, declaring: .zeroMinimum)

        let commanded = try await plane.commandTarget(fan.target(for: 0))

        #expect(commanded.rpm == FanSafetyLimits.minimumManualRPM)
        let attempts = await plane.attempts
        #expect(attempts == [.commandTarget(fan: 0, rpm: FanSafetyLimits.minimumManualRPM)])
    }

    // MARK: - Nothing here may cross the boundary

    /// The permits are `AeolusHelper`-internal so that a client cannot name them, and a
    /// `Codable` conformance would undo that by making them expressible in a payload. The
    /// same applies to the `FanKit` type they wrap: `FanTargetRPM`'s "no public initialiser,
    /// no `Codable`" is the producer half of this entire guarantee and had no assertion of
    /// any kind on it, while the consumer half got four.
    ///
    /// A synthesised `init(from:)` is a public initialiser taking an arbitrary number.
    @Test("No authorisation type is Codable, in either direction")
    func noAuthorisationTypeIsCodable() {
        #expect(!(FanTargetRPM.self is any Encodable.Type))
        #expect(!(FanTargetRPM.self is any Decodable.Type))
        #expect(!(AuthorisedFanTarget.self is any Encodable.Type))
        #expect(!(AuthorisedFanTarget.self is any Decodable.Type))
        #expect(!(CommandableFan.self is any Encodable.Type))
        #expect(!(CommandableFan.self is any Decodable.Type))
    }

    /// The mint is singular only because every stored property is `private`, and that is not
    /// something a runtime test can see — so it is asserted against the source, like every
    /// other structural claim in this repository.
    ///
    /// The hazard is specific and was live until review found it. A `fileprivate`
    /// initialiser confines the *initialiser*; Swift's "an initialiser in an extension must
    /// delegate" rule is cross-**module**, not cross-**file**. So while the stored properties
    /// were `let index: Int` and friends, any other file in the module could add
    ///
    /// ```swift
    /// extension CommandableFan {
    ///     init(forgedIndex: Int, envelope: FanControlEnvelope) { … }
    /// }
    /// ```
    ///
    /// and forge a permit for any fan without going near `FanEnvelope.commandable` — which
    /// reinstates the cross-fan defect this whole PR exists to close. It compiled. In `FanKit`
    /// the same shape was worse: `FanTargetRPM.rpm` was `public let`, so the forged
    /// initialiser would have been *public API* reachable from every client module.
    ///
    /// `private` members are unreachable from another file however the extension is written.
    ///
    /// **Both halves are load-bearing, and the count is what keeps this test honest.** A
    /// first version of this scan collected only lines containing `let`, so a stored `var`
    /// was invisible to it — and an internal stored `var` is worse than an internal `let`,
    /// because it does not merely let another file forge a permit, it lets one *re-point an
    /// already-minted, legitimately-read permit at a different fan*. A second gap sat beside
    /// it: nothing inspected the initialisers, so deleting `fileprivate` — making the mint
    /// `internal` and callable from every file in the module with an arbitrary index — left
    /// the whole suite green. Both are asserted now, and the expected count means a new
    /// member of any kind has to be acknowledged here rather than merely spelled carefully.
    @Test(
        "An authorisation type's stored properties are private and its initialisers fileprivate",
        arguments: [
            ("FanWriteAuthorisation.swift", "CommandableFan", 2),
            ("FanWriteAuthorisation.swift", "AuthorisedFanTarget", 2),
            ("FanControlEnvelope.swift", "FanTargetRPM", 1),
        ])
    func anAuthorisationTypeCannotBeMintedElsewhere(
        file: String, type: String, expectedStoredProperties: Int
    ) throws {
        let body = try SeamScanner.structBody(of: type, in: file)
        let lines =
            body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }

        // A computed property carries its accessor on the same line — `var rpm: Double {
        // clampedRPM }` — so the brace is what tells the two apart. Everything without one
        // is storage, whether it is spelled `let` or `var`.
        let stored = lines.filter {
            ($0.contains("let ") || $0.contains("var ")) && !$0.contains("{")
        }

        #expect(
            stored.count == expectedStoredProperties,
            """
            \(type) has \(stored.count) stored properties, expected \
            \(expectedStoredProperties): \(stored). Adding one is a decision about who can \
            mint a permit — acknowledge it here.
            """
        )
        for property in stored {
            #expect(
                property.hasPrefix("private "),
                """
                \(type) declares `\(property)`. A non-private stored property can be \
                assigned by an initialiser declared in an extension in any other file of \
                the same module, which forges a permit — see ADR 0008.
                """
            )
        }

        let initialisers = lines.filter { $0.contains("init(") }
        #expect(!initialisers.isEmpty, "\(type) declares no initialiser — this scan found none")
        for initialiser in initialisers {
            #expect(
                initialiser.hasPrefix("fileprivate init("),
                """
                \(type) declares `\(initialiser)`. Without `fileprivate` the mint is \
                internal and every file in the module can issue a permit for any fan. \
                `private` would be wrong in the other direction — `FanEnvelope.commandable` \
                is an extension on a different type and could no longer call it.
                """
            )
        }
    }

    // MARK: - The signatures that make the above true

    /// A source tripwire on the seam's declarations, in `WritePathAbsenceTests`' style.
    ///
    /// The behavioural tests above stop compiling if a signature reverts, which is a strong
    /// signal — but the realistic regression is not a revert. It is E3 or E4 adding a second
    /// verb "just for the unlock sequence", at which point everything above still compiles,
    /// still passes, and an ungoverned path exists beside the governed one.
    ///
    /// The assertion both write-verb tripwires share: **the permit is the sole parameter, in
    /// type position.**
    ///
    /// Two drafts of this were wrong, in instructive ways. The first blacklisted `: Double`
    /// on the target verb and `: Int` on the engage verb — the wrong way round on both, since
    /// the permit already carries the speed and what must not ride beside it is the index; so
    /// `commandTarget(_ target: AuthorisedFanTarget, ofFan index: Int)`, the *literal*
    /// signature ADR 0008 exists to make unrepresentable, passed green.
    ///
    /// The second required a permit name somewhere in the declaration and no comma. A
    /// substring test over the whole declaration reads argument labels and sibling type names
    /// too, so both of these passed:
    ///
    /// ```swift
    /// func engageManualControlForUnlock(ofCommandableFan index: Int) async throws
    /// func commandTargetPair(_ pair: AuthorisedFanTargetPair) async throws
    /// ```
    ///
    /// The first names no permit at all — only its *label* contains the word. The second
    /// takes a freely-constructible type whose name merely starts with the permit's.
    ///
    /// So the parameter clause is now parsed rather than searched: exactly one parameter,
    /// and the text after its single colon must equal the permit exactly. That rejects a
    /// companion parameter of any type, a label that impersonates a type, and a type whose
    /// name is a prefix or suffix of a permit's.
    private func expectPermitIsTheOnlyParameter(
        _ declaration: SeamScanner.Declaration, naming permit: String
    ) {
        let complaint = """
            \(declaration.file) declares `\(declaration.text)`. A write verb takes exactly \
            one parameter and its type is \(permit) — see ADR 0008. A value passed beside a \
            permit is a value that can disagree with it, and a label is not a type.
            """
        let parts = declaration.parameters.split(separator: ":", omittingEmptySubsequences: false)

        #expect(parts.count == 2, "\(complaint)")
        guard parts.count == 2 else { return }
        #expect(parts[1].trimmingCharacters(in: .whitespaces) == permit, "\(complaint)")
    }

    /// Matched by name *family* rather than the single name `commandTarget` — a scan bound to
    /// that one name was the first draft, and `commandTargetForUnlock` walks straight past it.
    /// The honest statement of what this covers, since the previous version of this comment
    /// claimed "by shape" and named only the smallest of its limitations:
    ///
    /// - It sees `func` declarations whose name contains `target`/`Target`, plus the sibling
    ///   scans below for `engage` and `restore`. **A verb named outside those three stems is
    ///   invisible to all three**, so `setFanSpeed` would escape. Closing that needs an
    ///   allowlist scan over every `async` function in the helper, which is #120.
    /// - The effects clause is `async` with `throws` optional. It is what separates a write
    ///   verb from a *producer*: `FanControlEnvelope.target(for:)` and
    ///   `CommandableFan.target(for:)` are also target-named functions taking a `Double`, and
    ///   they are the two that are supposed to. A synchronous write verb escapes, and that is
    ///   not contrived — `SMCConnection.write(_:to:)` is synchronous, so an E3/E4 wrapper
    ///   plausibly would be.
    /// - `[^)]*` cannot span a nested `)`, so a verb with a closure parameter is invisible.
    @Test("Every fan-target write verb in Sources takes a permit and nothing else")
    func everyTargetWriteVerbTakesAnAuthorisation() throws {
        let declarations = try SeamScanner.writeVerbs(named: #"\w*[Tt]arget\w*"#)

        #expect(
            declarations.count >= 2,
            """
            expected at least the protocol requirement and its production conformer, \
            found \(declarations.count) — this tripwire is not looking at the seam
            """
        )
        for declaration in declarations {
            expectPermitIsTheOnlyParameter(declaration, naming: "AuthorisedFanTarget")
        }
    }

    /// The mode verb, gated the same way and by the same assertion, so the two cannot drift
    /// apart again. `SAFETY.md` §2's "the only action such a fan is subject to is
    /// restore-to-automatic" is false the moment this one takes anything but a permit.
    @Test("Every manual-engage verb in Sources takes a permit and nothing else")
    func everyEngageVerbTakesAPermit() throws {
        let declarations = try SeamScanner.writeVerbs(named: #"engage\w*"#)

        #expect(declarations.count >= 2, "found \(declarations.count) engage declarations")
        for declaration in declarations {
            expectPermitIsTheOnlyParameter(declaration, naming: "CommandableFan")
        }
    }

    /// The inverse guard, and the one that matters most.
    ///
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone is that
    /// restore-to-automatic must never depend on trusted data: no bounds, no clamp, no
    /// reading, no lease. **A permit is trusted data.** The gate spreading to this verb would
    /// make the terminal action unavailable in precisely the case it exists for — the helper
    /// that cannot read — so the emptiness of these signatures is load-bearing, and is
    /// asserted rather than assumed. Every other test in this file pushes toward more gating;
    /// this is the one that says where it stops.
    ///
    /// The floor is **named declarations, not a count.** A bare `>= 2` was satisfied by
    /// `FanAuthority.restoreAllToAutomatic(from:)` and its read-only conformer, so both of the
    /// seam's own restore verbs could have stopped matching while the count still passed and
    /// the loop asserted nothing. And `throws` is optional here for a specific reason:
    /// `FanRestoring.restoreToAutomatic(fans:because:)` is deliberately non-throwing — it is
    /// the declaration `LeaseAuthority` actually calls — and an `async throws` pattern put the
    /// keystone seam outside the scan entirely.
    @Test("No restore verb in Sources takes an authorisation of any kind")
    func theRestoreVerbTakesNoAuthorisation() throws {
        let declarations = try SeamScanner.declarations(
            matching: #"func\s+restore\w*\s*\([^)]*\)\s*async(\s+throws)?"#)
        let permits = [
            "CommandableFan", "AuthorisedFanTarget", "FanTargetRPM", "FanControlEnvelope",
        ]

        // Both keystone declarations must be in the scan, by their payload types: the plane's
        // scope-only verb and the lease core's non-throwing one.
        #expect(
            declarations.contains { $0.text.contains("FanRestoreScope") },
            "the plane's restore verb is not in this scan")
        #expect(
            declarations.contains { $0.text.contains("FanRestoreCause") },
            "FanRestoring's non-throwing restore verb is not in this scan")

        for declaration in declarations {
            for permit in permits {
                #expect(
                    !declaration.text.contains(permit),
                    """
                    \(declaration.file) declares `\(declaration.text)`. The restore verb \
                    takes nothing but a scope — ADR 0007's keystone.
                    """
                )
            }
        }
    }

    /// The realistic way a permit reaches the keystone without appearing in a signature: not
    /// a parameter, but a field on the payload the signature already takes.
    @Test("The restore scope carries no authorisation either")
    func theRestoreScopeCarriesNoAuthorisation() throws {
        let scope = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == "FanControlPlane.swift" })
        let text = try String(contentsOf: scope, encoding: .utf8)
        let declaration = try #require(
            text.range(of: #"enum FanRestoreScope[^}]*\}"#, options: .regularExpression))

        for permit in ["CommandableFan", "AuthorisedFanTarget", "FanTargetRPM"] {
            #expect(
                !text[declaration].contains(permit),
                "FanRestoreScope carries a \(permit) — ADR 0007's keystone, by the back door")
        }
    }
}
