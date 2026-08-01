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
        let text = try ClientRequirementText.build(teamIdentifier: team, variant: variant).get()
        return try compile(text)
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

    /// Shared with `UnsignedBinaryFixture`, which strips a signature with the same tool.
    static func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
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
