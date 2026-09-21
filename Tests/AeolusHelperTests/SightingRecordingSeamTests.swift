import Foundation
import Testing

@testable import AeolusHelper

/// **Where `beganReading()` is called, which is the half of
/// [#280](https://github.com/blamechris/Aeolus/issues/280) no type can express.**
///
/// `CriticalTemperatureReadingStart` stops a caller *forging* an instant: the initialiser and
/// the stored value are both `fileprivate` to `CriticalTemperatureCache.swift`, so the only
/// way to obtain one is to ask the cache. That is enforced by the compiler and needs no test.
///
/// It does **not** stop a caller stamping the instant at the wrong *time*. `beganReading()` is
/// callable at any moment, and this compiles:
///
/// ```swift
/// let report = try await telemetry.readCriticalTemperatures()
/// await sightings.record(.sighted(report), since: sightings.beganReading())
/// ```
///
/// That is #280 restored in full — a start no older than the reading makes the comparison
/// vacuous — with an exposed window equal to the whole 6–20 ms read. And it passes every other
/// guard in this repository: it adds no construction, so `onlyOneSightingCacheIsEverBuilt` is
/// unmoved; it names no concrete type, so `onlyTheConcreteCacheAnnotationIsInTheCompositionRoot`
/// is unmoved; it declares no new `async` function, so `everyVerbIsAcknowledged` is unmoved.
/// The two behavioural tests that *would* catch it —
/// `aCycleDoesNotOverwriteABlindnessRecordedDuringItsRead` and
/// `aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway` — drive the two callers that exist
/// today, and a **third** caller is invisible to both.
///
/// This defect class has now shipped twice by exactly that route: #279's guard was a no-op in
/// the daemon and green in CI, and #280 is its cycle-side twin. So the call sites are counted
/// rather than trusted, on `PanicPathScopeTripwireTests`' pattern — a third one is an
/// acknowledgement rather than an edit.
@Suite("Every reading start is minted before the read it describes")
struct SightingRecordingSeamTests {

    /// The two sites, each naming why it is one.
    ///
    /// `CriticalTemperatureCache.sighting()` mints before it launches the flight;
    /// `ThermalEmergency.cycle()` mints before it reads § 3's curated set. There is no third
    /// reader of the curated critical set in the helper — every caller of
    /// `readCriticalTemperatures()` is one of these two.
    private static let expected = [
        "CriticalTemperatureCache.swift x1",
        "ThermalEmergency.swift x1",
    ]

    /// **Mutation:** add a third call — e.g. change `ThermalEmergency.cycle()`'s record to
    /// `since: sightings.beganReading()` while leaving line 283 in place. Run: red, naming
    /// `ThermalEmergency.swift x2`. Deleting a call site is red too, which is the half that
    /// stops this decaying into an emptiness check that passes for ever.
    @Test("beganReading() is called in exactly the two places that read the curated set")
    func beganReadingHasExactlyTwoCallSites() throws {
        var sites: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            // Normalised before matching: `beganReading ()` with a space compiles, and a scan
            // whose soundness rests on the formatter having run has an unstated precondition
            // — the hole Copilot found in #283's guard.
            let normalised = code.replacingOccurrences(of: " (", with: "(")
            let count = Self.occurrences(of: "beganReading()", in: normalised)
            // The declaration in the protocol and the conformer are declarations, not calls;
            // both are followed by `-> CriticalTemperatureReadingStart` or `async`, so they
            // are excluded by requiring a receiver or an assignment rather than by a line
            // filter — a filter added to dodge a false positive becomes the evasion.
            let calls = count - Self.occurrences(of: "func beganReading()", in: normalised)
            if calls > 0 { sites.append("\(file.lastPathComponent) x\(calls)") }
        }

        #expect(
            sites.sorted() == Self.expected,
            """
            beganReading() is called in \(sites.sorted()), expected \(Self.expected). A start \
            must be minted BEFORE the read it describes — see #280. A new call site is a new \
            reader of the curated critical set, and it has to prove its stamp precedes its \
            read with a test of its own, the way \
            aCycleDoesNotOverwriteABlindnessRecordedDuringItsRead does. Adding an entry here \
            without that test re-opens #280.
            """)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    /// Duplicated from `HelperCompositionTests` for the reason that file's own copy states:
    /// a single definition reachable from both is one edit away from being changed for both.
    private static func strippingComments(_ source: String) -> String {
        SeamScanner.strippingComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }
}
