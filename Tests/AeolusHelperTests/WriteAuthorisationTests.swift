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

    // MARK: - The signatures that make the above true

    /// A source tripwire on the seam's declarations, in `WritePathAbsenceTests`' style.
    ///
    /// The behavioural tests above stop compiling if a signature reverts, which is a strong
    /// signal — but the realistic regression is not a revert. It is E3 or E4 adding a second
    /// verb "just for the unlock sequence", at which point everything above still compiles,
    /// still passes, and an ungoverned path exists beside the governed one.
    ///
    /// Matched by *shape* rather than by the single name `commandTarget`: a name-bound scan
    /// was the first draft of this test, and `commandTargetForUnlock` walks straight past it.
    ///
    /// `async throws` is part of the pattern, and it is what separates a write verb from a
    /// producer. `FanControlEnvelope.target(for:)` and `CommandableFan.target(for:)` are also
    /// target-named functions taking a `Double`, and they are the two functions that are
    /// *supposed* to — they mint the authorisation rather than consume it. Without that
    /// clause this test fails on the very machinery it exists to protect. The limitation it
    /// buys, stated plainly as `WritePathAbsenceTests` states its own: a synchronous write
    /// verb would escape. Nothing that talks to the SMC on this seam is synchronous.
    @Test("Every fan-target write verb in Sources takes an authorisation, never a bare number")
    func everyTargetWriteVerbTakesAnAuthorisation() throws {
        let declarations = try SeamScanner.declarations(
            matching: #"func\s+\w*[Tt]arget\w*\s*\([^)]*\)\s*async\s+throws"#)

        #expect(
            declarations.count >= 2,
            """
            expected at least the protocol requirement and its production conformer, \
            found \(declarations.count) — this tripwire is not looking at the seam
            """
        )

        for declaration in declarations {
            #expect(
                declaration.text.contains("AuthorisedFanTarget"),
                """
                \(declaration.file) declares `\(declaration.text)`. A fan target crosses \
                this seam as an AuthorisedFanTarget or it does not cross it — see ADR 0008.
                """
            )
            // Containment alone would pass a verb taking BOTH an authorisation and a bare
            // number, which is the convenience overload this tripwire exists to catch.
            #expect(
                !declaration.text.contains(": Double"),
                "\(declaration.file) declares `\(declaration.text)`, which takes a bare number"
            )
        }
    }

    /// The mode verb, gated the same way. `SAFETY.md` §2's "the only action such a fan is
    /// subject to is restore-to-automatic" is false the moment this one takes an index.
    @Test("Every manual-engage verb in Sources takes a permit, never an index")
    func everyEngageVerbTakesAPermit() throws {
        let declarations = try SeamScanner.declarations(
            matching: #"func\s+engage\w*\s*\([^)]*\)\s*async\s+throws"#)

        #expect(declarations.count >= 2, "found \(declarations.count) engage declarations")
        for declaration in declarations {
            #expect(
                declaration.text.contains("CommandableFan"),
                "\(declaration.file) declares `\(declaration.text)`, which is ungated")
            #expect(
                !declaration.text.contains(": Int"),
                "\(declaration.file) declares `\(declaration.text)`, which takes an index")
        }
    }

    /// The inverse guard, and the one that matters most.
    ///
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone is that
    /// restore-to-automatic must never depend on trusted data: no bounds, no clamp, no
    /// reading, no lease. **A permit is trusted data.** The gate spreading to this verb would
    /// make the terminal action unavailable in precisely the case it exists for — the helper
    /// that cannot read — so the emptiness of this signature is load-bearing, and is asserted
    /// rather than assumed. Every other test in this file pushes in the direction of more
    /// gating; this is the one that says where it stops.
    @Test("No restore verb in Sources takes an authorisation of any kind")
    func theRestoreVerbTakesNoAuthorisation() throws {
        let declarations = try SeamScanner.declarations(
            matching: #"func\s+restore\w*\s*\([^)]*\)\s*async\s+throws"#)
        let permits = [
            "CommandableFan", "AuthorisedFanTarget", "FanTargetRPM", "FanControlEnvelope",
        ]

        #expect(declarations.count >= 2, "found \(declarations.count) restore declarations")
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
}

/// Scans `Sources` for function declarations, so a signature can be asserted as a property of
/// the source tree rather than of a call site.
///
/// Extracted rather than copied. `WritePathAbsenceTests` had the enumerator and the
/// comment-stripping filter first, and a second verbatim copy of a scanner that must agree
/// with the original is exactly the duplication this repository's style spells out once.
enum SeamScanner {

    struct Declaration {
        let file: String
        let text: String
    }

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the project's sources were not found")
        return files
    }

    /// Every declaration under `Sources` matching `pattern`, with its parameter list.
    ///
    /// Comment lines are dropped first, for the reason `WritePathAbsenceTests` records: the
    /// prose describing a forbidden signature is not that signature, and a tripwire that
    /// fires on the sentence explaining the rule is a tripwire nobody keeps. The trade is
    /// that a declaration inside a block comment is invisible — contrived, where an added
    /// verb is not.
    static func declarations(matching pattern: String) throws -> [Declaration] {
        let expression = try NSRegularExpression(pattern: pattern)
        var found: [Declaration] = []

        for file in try swiftFiles() {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for match in expression.matches(in: code, range: range) {
                guard let matched = Range(match.range, in: code) else { continue }
                found.append(
                    Declaration(
                        file: file.lastPathComponent,
                        text: String(code[matched]).replacingOccurrences(of: "\n", with: " ")))
            }
        }
        return found
    }
}
