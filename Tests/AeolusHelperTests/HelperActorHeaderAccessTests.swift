import Foundation
import Testing

/// The access an actor's own declaration, and each `extension` of it, gives the members written
/// under it ([#610](https://github.com/blamechris/Aeolus/issues/610)).
///
/// `HelperConnectionSessionAccessTests`, `LeaseAuthorityAccessTests` and
/// `ReclamationWatchdogAccessTests` pin each member of their actor as spelled, which closes a
/// widening written on the member's own line or the one above it. None of them can see one
/// written on a header. An `extension`'s modifier is the default for every member in the block and
/// sits on none of their lines, and the actor's own modifier decides what an extension may carry.
/// So the headers are pinned here, as written, for the reason `HelperClientExtensionAccessTests`
/// gives for the client's. `RoleCensus` begins a statement at the `actor` introducer (read, not
/// run), so a modifier in front of it goes unseen there too.
///
/// ## `public` is the spelling only this suite catches
///
/// `package` is not the reason this suite exists. `WriteSeamAccessTests.
/// noSourceFileDeclaresPackageAccess` refuses it on every declaration under `Sources`, on the
/// line above one included, so a `package` header is red there in a full run whatever happens
/// here. `public` is refused by nothing else. Measured on a scratch edit: `public actor
/// LeaseAuthority: HeldLeaseRole {` with `public extension LeaseAuthority {` on the extension in
/// `LeaseAuthorityHandbackRegisters.swift` compiles, and with this suite's assertions removed the
/// whole target is green. Deleting this suite on the grounds that `package` is banned leaves that
/// edit unguarded.
///
/// ## The route is two edits, and the compiler decides how far it goes
///
/// Swift rejects `public extension LeaseAuthority {` against an internal actor ("extension of
/// internal actor cannot be declared public"; `package` fails the same way), so widening an
/// extension first needs the actor's own declaration widened, and only then the extension.
/// Measured on scratch edits to the sources, for `public`:
///
/// - `public actor LeaseAuthority` and `public actor HelperConnectionSession` compile. With the
///   first, `public extension LeaseAuthority {` compiles on the two extensions that declare a
///   value type (`LeaseAuthorityHandbackRegisters.swift` and
///   `LeaseAuthoritySleepSealPairing.swift`) and fails on `LeaseAuthorityRefusals.swift`, whose
///   methods take internal types. With the second, both of the session's extensions
///   (`HelperConnectionSessionGates.swift` and `HelperConnectionSessionMessages.swift`) fail
///   because their methods return internal types.
/// - `public actor ReclamationWatchdog<Plane: FanControlPlane>` does not compile ("generic actor
///   cannot be declared public because its generic parameter uses an internal type"; `package`
///   fails the same way), and a `package` `FanControlPlane` fails on its own requirements. So the
///   watchdog's lines are pinned ahead of a route the compiler closes today.
///
/// Both lines are pinned, and each is red on its own. A real widening is a review, and is
/// re-stated here.
///
/// ## What is compared
///
/// An actor's declaration is its line, trimmed, behind any modifier-only lines above it
/// (`MemberAccessScan.declaration(of:in:from:)`). An extension's is
/// `MemberAccessScan.extensionHeaders(of:inTarget:)`'s, as `File.swift: header`. Both are exact,
/// so a conformance, a generic clause or a trailing comment is part of the header. A conformance
/// extension (`extension ReclamationWatchdog: ReclamationReporting {}`) takes no access
/// modifier ("'package' modifier cannot be used with extensions that declare protocol
/// conformances"), so it cannot be widened that way; it is pinned as written like the rest.
///
/// ## What this does not reach
///
/// - **An extension reached through a `typealias`.** `ReclamationWatchdogAccessTests` and
///   `LeaseAuthorityRegistersAccessTests` refuse an alias of their actors;
///   `HelperConnectionSession` has no such check.
/// - **A nested type's header** (`Registry`, `Registration`, `HeldFan`, `Judgement`,
///   `HandbackRegisters`, `SleepSealPairing`, `SealOutcome`) is read by no suite. Its access is
///   capped by the actor it sits in, so it matters only after the headers pinned here have been
///   widened. Measured: `public struct HeldFan` compiles and leaves the access suites green.
@Suite("The helper actors' own declarations and extensions are written without a modifier")
struct HelperActorHeaderAccessTests {

    /// One actor: where it is declared, its declaration, and every extension of it.
    private struct HelperActor {
        let type: String
        let file: String
        /// What `declaration(of:in:from:)` reads for `actor <type>`, behind any modifier above.
        let declaration: String
        /// What `extensionHeaders(of:inTarget:)` reads, sorted.
        let extensions: [String]
    }

    private static let helperTarget = "AeolusHelper"

    /// `ReclamationReporting.swift` holds the watchdog's conformance to the snapshot's role and no
    /// member (#410), so its header is the whole of the extension.
    private static let reportingConformance =
        "ReclamationReporting.swift: extension ReclamationWatchdog: ReclamationReporting {}"

    /// The three actors whose members the access suites pin. Nine extensions between them.
    private static let actors = [
        HelperActor(
            type: "HelperConnectionSession", file: "HelperConnectionSession.swift",
            declaration: "actor HelperConnectionSession {",
            extensions: [
                "HelperConnectionSessionGates.swift: extension HelperConnectionSession {",
                "HelperConnectionSessionMessages.swift: extension HelperConnectionSession {",
            ]),
        HelperActor(
            type: "LeaseAuthority", file: "LeaseAuthority.swift",
            declaration: "actor LeaseAuthority: HeldLeaseRole {",
            extensions: [
                "LeaseAuthorityHandbackRegisters.swift: extension LeaseAuthority {",
                "LeaseAuthorityRefusals.swift: extension LeaseAuthority {",
                "LeaseAuthoritySleepSealPairing.swift: extension LeaseAuthority {",
            ]),
        HelperActor(
            type: "ReclamationWatchdog", file: "ReclamationWatchdog.swift",
            declaration:
                "actor ReclamationWatchdog<Plane: FanControlPlane>: ReclamationRegistrationRole {",
            extensions: [
                "ReclamationHeldFan.swift: extension ReclamationWatchdog {",
                "ReclamationRegistry.swift: extension ReclamationWatchdog {",
                Self.reportingConformance,
                "ReclamationSignals.swift: extension ReclamationWatchdog {",
            ]),
    ]

    /// **Mutations:** write `public actor LeaseAuthority: HeldLeaseRole {`; the same for
    /// `HelperConnectionSession`. Write `package actor LeaseAuthority: HeldLeaseRole {`, or put
    /// `package` alone on the line above it; `WriteSeamAccessTests` is red on those two as well.
    /// Put `internal` alone on the line above `actor ReclamationWatchdog<…>`, for which `public`
    /// and `package` do not compile. Run: red here at the comparison, on each.
    @Test("Each helper actor is declared in its own file, without a modifier")
    func everyActorIsDeclaredWithoutAModifier() throws {
        for helper in Self.actors {
            let sites = try MemberAccessScan.filesDeclaring(
                helper.type, inTarget: Self.helperTarget)
            #expect(
                sites.declarations == [helper.file],
                """
                \(helper.type) is declared in \(sites.declarations), and this suite reads \
                \(helper.file). Read the declaration where it now is, and re-state it here.
                """
            )

            let code = try MemberAccessScan.strippedSource(of: helper.file)
            let found = try MemberAccessScan.declaration(
                of: "actor \(helper.type)", in: code, from: helper.file)
            #expect(
                found == helper.declaration,
                """
                the declaration of \(helper.type) changed: found `\(found)`, expected \
                `\(helper.declaration)`. A modifier on the actor decides what an extension of it \
                may carry, and `package extension` needs it; a real modifier is a widening to \
                review, and is re-stated here.
                """
            )
        }
    }

    /// **Mutations:** write `public actor LeaseAuthority` with `public extension LeaseAuthority
    /// {` on the extension in `LeaseAuthorityHandbackRegisters.swift`, or on the one in
    /// `LeaseAuthoritySleepSealPairing.swift`, or with `public` alone on the line above it. Run:
    /// red here and in the declaration test, and nowhere else in the target. The same with
    /// `package` is red in `WriteSeamAccessTests` too. Put `internal` alone on the line above
    /// `extension ReclamationWatchdog {` in `ReclamationSignals.swift`. Run: red here.
    @Test("Every extension of a helper actor is written without a modifier")
    func everyExtensionOfAnActorIsBare() throws {
        for helper in Self.actors {
            let found = try MemberAccessScan.extensionHeaders(
                of: helper.type, inTarget: Self.helperTarget)
            #expect(
                found == helper.extensions,
                """
                the extensions of \(helper.type) changed: found \(found), expected \
                \(helper.extensions). A modifier on an extension is the access of every member \
                inside it and is on none of their lines, so `package extension` widens the whole \
                block past what the access suites pin. Keep the header bare, with any comment on \
                the line above; a new extension is a file the access suites must scan, and is \
                re-stated here.
                """
            )
        }
    }
}
