import Foundation
import Security
import Testing

@testable import AeolusXPC

/// Shared fixtures for the client authorisation suites (E2.2).
///
/// See `ClientAuthorisationTests.swift` for what these tests can and cannot establish
/// without a signing identity — read that before adding one.
enum ClientAuthorisationFixtures {

    /// A Team ID shaped like Apple's, belonging to nobody.
    static let team = "ABCDE12345"

    /// Both variants, so a variant added later is covered by every parameterised test
    /// rather than silently skipped by a hand-written pair.
    static let variants = ClientRequirementVariant.allCases

    static let refusals: [ClientAuthorisationRefusal] = [
        .helperHasNoTeamIdentifier,
        .selfInspectionFailed(errSecCSUnsigned),
        .teamIdentifierNotWellFormed(.empty),
        .teamIdentifierNotWellFormed(.unacceptableCharacters),
        .teamIdentifierNotWellFormed(.tooLong),
        .requirementDidNotCompile(errSecCSReqInvalid),
        .negativeControlUnavailable(errSecCSStaticCodeNotFound),
        .negativeControlAdmittedForeignCode,
    ]

    static func compiledRequirement(variant: ClientRequirementVariant) throws -> SecRequirement {
        try compile(try text(variant: variant))
    }

    static func text(variant: ClientRequirementVariant) throws -> String {
        try ClientRequirementText.build(teamIdentifier: team, variant: variant).get()
    }

    /// The production text with exactly one pair of parentheses removed: the ones around the
    /// identifier disjunction.
    ///
    /// Derived from the production text rather than written out, so this is the real
    /// requirement with one real defect in it. `and` binds tighter than `or`, so the result
    /// parses as `(everything and one identifier) or (the other identifier …)` — and the
    /// second alternative pins nothing at all.
    ///
    /// The `#require` is the vacuity guard: if the identifier clause is ever built some other
    /// way, this stops silently returning the text unchanged and starts failing.
    static func unparenthesisedIdentifierDisjunction(
        variant: ClientRequirementVariant
    ) throws -> String {
        let alternatives = AeolusClientIdentifier.all
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        let built = try text(variant: variant)
        try #require(built.contains("(\(alternatives))"))
        return built.replacingOccurrences(of: "(\(alternatives))", with: alternatives)
    }

    /// Clauses of the Release requirement that a careless edit could drop, spelled as they
    /// appear in the built text.
    ///
    /// Literals, because the builder assembles them privately — but literals that
    /// `releaseTextDeleting` proves are still present before it removes one, so a clause that
    /// changed shape turns this into a red test rather than a no-op deletion.
    static let deletableConjuncts = [
        "certificate leaf[subject.OU] = \"\(team)\"",
        "certificate 1[field.1.2.840.113635.100.6.2.6] "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13]",
    ]

    /// The Release text with one conjunct removed, `and` separator included.
    static func releaseTextDeleting(_ conjunct: String) throws -> String {
        let built = try text(variant: .release)
        try #require(built.contains("\(conjunct) and "))
        return built.replacingOccurrences(of: "\(conjunct) and ", with: "")
    }

    static func compile(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        return try #require(requirement)
    }

    static func satisfies(_ requirement: SecRequirement, _ path: String) -> Bool {
        checkValidity(requirement, path) == errSecSuccess
    }

    /// The raw status, for the tests that care *which* failure it was — the distinction
    /// `RequirementNegativeControl` now turns on.
    static func checkValidity(_ requirement: SecRequirement, _ path: String) -> OSStatus {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return status }
        // The same flags RequirementNegativeControl uses, taken from it rather than
        // restated, for the same reason it names them: a test that can reach the network is
        // a test that can fail for reasons unrelated to what it asserts.
        let flags = RequirementNegativeControl.validationFlags
        return SecStaticCodeCheckValidity(code, flags, requirement)
    }
}

/// A copy of an Apple binary with its signature stripped off.
///
/// The point of this fixture is that it is a file the Security framework can open and then
/// refuses to evaluate — `SecStaticCodeCreateWithPath` succeeds, and
/// `SecStaticCodeCheckValidity` fails with `errSecCSUnsigned` before the requirement is
/// consulted at all. That is a different failure from a probe that is simply missing, and
/// it is the one that used to be indistinguishable from "the requirement rejected it".
///
/// Built at test time with `codesign --remove-signature`, which needs no signing identity
/// and so works on CI. Nothing executes it; it is only ever read.
struct UnsignedBinaryFixture {
    let directory: URL
    /// A real Mach-O with no code signature.
    let path: String

    static func make() throws -> UnsignedBinaryFixture {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("aeolus-unsigned-probe-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let binary = directory.appendingPathComponent("unsigned")
        try manager.copyItem(
            at: URL(fileURLWithPath: RequirementNegativeControl.systemProbePath),
            to: binary
        )
        try AdHocSignedFixtures.codesign(["--remove-signature", binary.path])

        return UnsignedBinaryFixture(directory: directory, path: binary.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Two copies of the same Apple binary, re-signed ad hoc, differing only in whether they
/// carry `com.apple.security.get-task-allow`.
///
/// Built rather than found: every binary lying around is debuggable or not for reasons
/// that could change under a toolchain update and quietly make a test vacuous. Ad-hoc
/// signing needs no identity, so this works on CI. `/bin/ls` is the base because it is
/// present on every Mac, is tiny, and re-signs cleanly; nothing depends on it being `ls`.
struct AdHocSignedFixtures {
    let directory: URL
    /// Ad-hoc signed, no entitlements.
    let plain: String
    /// Ad-hoc signed, carrying `get-task-allow`.
    let debuggable: String

    enum Failure: Error {
        case codesignFailed(arguments: [String], status: Int32)
    }

    static func make() throws -> AdHocSignedFixtures {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("aeolus-client-auth-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = URL(fileURLWithPath: RequirementNegativeControl.systemProbePath)
        let plain = directory.appendingPathComponent("plain")
        let debuggable = directory.appendingPathComponent("debuggable")
        try manager.copyItem(at: source, to: plain)
        try manager.copyItem(at: source, to: debuggable)

        let entitlements = directory.appendingPathComponent("debuggable.entitlements")
        try entitlementsPlist.write(to: entitlements, atomically: true, encoding: .utf8)

        try codesign(["--force", "--sign", "-", plain.path])
        try codesign(
            ["--force", "--sign", "-", "--entitlements", entitlements.path, debuggable.path]
        )

        return AdHocSignedFixtures(
            directory: directory,
            plain: plain.path,
            debuggable: debuggable.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The signing tool every fixture in this file shells out to.
    static let codesignPath = "/usr/bin/codesign"

    /// Whether `codesign` is present and runnable on this host.
    ///
    /// It ships with macOS and with the Command Line Tools, so it is there on CI and on the
    /// maintainer's machine alike; this exists so that a host where it is genuinely absent
    /// skips the fixtures that need it with a reason on the record, rather than failing a
    /// suite for a reason that has nothing to do with client authorisation.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: codesignPath)
    }

    /// Shared with `UnsignedBinaryFixture`, which strips a signature with the same tool.
    static func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codesignPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.codesignFailed(arguments: arguments, status: process.terminationStatus)
        }
    }

    private static let entitlementsPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>com.apple.security.get-task-allow</key>
        <true/>
        </dict>
        </plist>
        """
}

/// A copy of an Apple binary, ad-hoc re-signed to wear one of Aeolus's own client
/// identifiers — no team, no certificate chain, and no Apple anchor over the new signature.
///
/// This is the probe the startup negative control does not have. `/bin/ls` is Apple-team
/// platform code, so it can only catch a requirement that admits Apple platform binaries.
/// This fixture is the other shape: code that is *not* Apple's and that claims to be
/// `fanctl`. A requirement whose identifier disjunction lost its parentheses admits it
/// outright, because `and` binds tighter than `or` and the trailing `identifier "…"` then
/// stands alone as a complete alternative.
///
/// Built with `codesign --sign - --force --identifier` (`-s - -f -i`), which needs no
/// signing identity and so works on CI. Nothing executes it; it is only ever read.
struct AeolusIdentifiedProbeFixture {
    let directory: URL
    /// A real Mach-O, ad-hoc signed, whose designated identifier is `identifier`.
    let path: String

    /// One of the two identifiers the production requirement admits, taken from the
    /// production constant rather than restated — a probe wearing a stale identifier would
    /// be refused for the wrong reason and would prove nothing.
    static let identifier = AeolusClientIdentifier.commandLine

    static func make() throws -> AeolusIdentifiedProbeFixture {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("aeolus-identified-probe-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let binary = directory.appendingPathComponent("client")
        try manager.copyItem(
            at: URL(fileURLWithPath: RequirementNegativeControl.systemProbePath),
            to: binary
        )
        try AdHocSignedFixtures.codesign(
            ["--sign", "-", "--force", "--identifier", Self.identifier, binary.path]
        )

        return AeolusIdentifiedProbeFixture(directory: directory, path: binary.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
