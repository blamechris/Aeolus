import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// `FanTargetRPM` is only a guarantee if the write seam actually consumes it.
///
/// [#108](https://github.com/blamechris/Aeolus/issues/108) is the gap this suite closes.
/// `FanControlEnvelope` claims that *"a write path that takes a `FanTargetRPM` cannot be
/// handed a raw `Double` that skipped the clamp"* — and until now no write path took one.
/// `commandTarget` was typed on `Double` with a doc comment asking callers to clamp first,
/// which made `CLAUDE.md` rules 3 and 4 a matter of convention at the last hop before
/// firmware. The type is the control; these are the tests that say so.
///
/// Two kinds of assertion, because the property has two halves. The behavioural tests show
/// that a hostile number cannot survive the trip to the seam. The tripwire shows that the
/// signature which makes that true has not been widened back.
@Suite("The write seam is typed on a clamped target")
struct TypedWriteSeamTests {

    // MARK: - A hostile number cannot reach the firmware

    /// The case `CLAUDE.md` rule 3 exists for, at the last hop before firmware.
    ///
    /// A fan whose firmware declares a minimum of zero is real — `docs/RECOVERY.md` records
    /// fans stopping at idle as normal on many Macs — so `[F0Mn, F0Mx]` alone permits
    /// commanding a stop. Asking for zero on such a fan must arrive at the seam as
    /// `FanSafetyLimits.minimumManualRPM`, and the only reason it does is that the request
    /// had to pass through an envelope to become something `commandTarget` would accept.
    @Test("Commanding zero on a fan declaring a zero minimum reaches the seam as the floor")
    func zeroIsFlooredBeforeItReachesTheSeam() async throws {
        let plane = ScriptedControlPlane(fans: [0: .zeroMinimum], stages: [.nominal()])

        let commanded = try await plane.commandTarget(
            FanControlEnvelope.zeroMinimum.target(for: 0), ofFan: 0)

        #expect(commanded.rpm == FanSafetyLimits.minimumManualRPM)
        let attempts = await plane.attempts
        #expect(attempts == [.commandTarget(fan: 0, rpm: FanSafetyLimits.minimumManualRPM)])

        // And the firmware really holds that value, rather than the seam merely reporting
        // it: a clamp that is applied to the return value and not to the write would pass
        // the assertion above and still stop the fan.
        let state = try await plane.readControlState(ofFan: 0)
        #expect(state.target == .rpm(FanSafetyLimits.minimumManualRPM))
    }

    /// NaN is the request the clamp arithmetic cannot answer — every comparison with it is
    /// false, so `min(max(_:_:)_:)` returns it unchanged — and it resolves to the floor.
    /// Reaching the seam at all would put a NaN into `F<n>Tg`.
    @Test("A NaN request reaches the seam as the floor, never as NaN")
    func nanIsFlooredBeforeItReachesTheSeam() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.nominal()])

        let commanded = try await plane.commandTarget(
            FanControlEnvelope.nominal.target(for: .nan), ofFan: 0)

        #expect(commanded.rpm.isFinite, "a NaN reached the write seam")
        #expect(commanded.rpm == 1_350)
    }

    /// The other end. A request above the firmware maximum arrives as the maximum, because
    /// rule 4 permits narrowing the firmware's range and nothing else.
    @Test("A request above the firmware maximum reaches the seam as the maximum")
    func anExcessiveRequestArrivesAsTheFirmwareMaximum() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.nominal()])

        let commanded = try await plane.commandTarget(
            FanControlEnvelope.nominal.target(for: 1_000_000), ofFan: 0)

        #expect(commanded.rpm == 5_777)
    }

    /// A negative request is not a speed. It floors like every other out-of-range value,
    /// rather than being refused here — refusal is the outer boundary's job, and this is
    /// the last line rather than the only one.
    @Test("A negative request reaches the seam as the floor")
    func aNegativeRequestArrivesAsTheFloor() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.nominal()])

        let commanded = try await plane.commandTarget(
            FanControlEnvelope.nominal.target(for: -4_200), ofFan: 0)

        #expect(commanded.rpm == 1_350)
    }

    // MARK: - The signature that makes the above true

    /// A source tripwire on the seam's own declaration, in the style of
    /// `WritePathAbsenceTests`.
    ///
    /// The behavioural tests above stop compiling if `commandTarget` goes back to taking a
    /// `Double`, which is a strong signal — but the realistic regression is not a revert.
    /// It is E3 or E4 adding a second overload "just for the unlock sequence", or a
    /// conformer declaring one, at which point the typed one still exists, every test above
    /// still compiles and still passes, and an unclamped path exists beside it. This is the
    /// assertion that fires on that.
    @Test("No declaration of a fan-target write verb in Sources takes a bare Double")
    func noWriteVerbTakesABareDouble() throws {
        let declarations = try Self.commandTargetDeclarations()

        // Without this, a regex that matched nothing — or a `sourcesRoot` that resolved
        // wrongly — would make zero assertions and report the seam safe. This suite exists
        // because a guarantee wired to nothing looked exactly like a guarantee.
        #expect(
            declarations.count >= 2,
            """
            expected at least the protocol requirement and its production conformer, \
            found \(declarations.count) — this tripwire is not looking at the seam
            """
        )

        for declaration in declarations {
            #expect(
                declaration.text.contains("FanTargetRPM"),
                """
                \(declaration.file) declares `\(declaration.text)`, which takes an \
                unclamped number. A fan target crosses this seam as a FanTargetRPM or it \
                does not cross it — see issue #108.
                """
            )
        }
    }

    // MARK: - Scanning

    private struct Declaration {
        let file: String
        let text: String
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    /// Every `func commandTarget(...)` declared under `Sources`, with its parameter list.
    ///
    /// Comment lines are dropped first, for the reason `WritePathAbsenceTests` records: this
    /// file's own prose describes the signature it forbids, and a tripwire that fires on the
    /// sentence explaining the rule is a tripwire nobody keeps.
    private static func commandTargetDeclarations() throws -> [Declaration] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the project's sources were not found")

        let pattern = try NSRegularExpression(pattern: #"func\s+commandTarget\s*\([^)]*\)"#)
        var found: [Declaration] = []

        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for match in pattern.matches(in: code, range: range) {
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
