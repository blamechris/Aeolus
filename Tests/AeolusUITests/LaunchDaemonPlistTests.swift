import AeolusXPC
import Foundation
import Testing

@testable import AeolusUI

/// The launchd job description is a file three separate things have to agree about: the
/// code that names it (`HelperBundleLayout`), the mach service clients connect to
/// (`AeolusXPCService`), and the build script that copies it into the bundle. A
/// disagreement between them does not fail to build and does not fail to register — it
/// produces a daemon that installs and then never starts, or one clients cannot reach,
/// which is a considerably worse way to find out.
///
/// Reads the file from the source tree via `#filePath` rather than from a test bundle
/// resource: the point is to check the artefact that actually ships, not a copy of it.
@Suite("The launchd plist, the layout constants, and the mach service name agree")
struct LaunchDaemonPlistTests {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    private static var plistURL: URL {
        repositoryRoot
            .appendingPathComponent("Configs/LaunchDaemons")
            .appendingPathComponent(HelperBundleLayout.daemonPlistName)
    }

    private func loadPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.plistURL)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return try #require(parsed as? [String: Any])
    }

    @Test("The file HelperBundleLayout names is the file that exists in Configs/LaunchDaemons")
    func plistExistsUnderTheNameTheCodeUses() {
        #expect(FileManager.default.fileExists(atPath: Self.plistURL.path))
    }

    @Test("Label matches the mach service name clients connect to")
    func labelMatchesMachServiceName() throws {
        let plist = try loadPlist()
        #expect(plist["Label"] as? String == AeolusXPCService.machServiceName)
    }

    @Test("BundleProgram points at where the build script actually puts the helper")
    func bundleProgramMatchesTheEmbeddedPath() throws {
        let plist = try loadPlist()
        #expect(plist["BundleProgram"] as? String == HelperBundleLayout.executableBundlePath)
    }

    @Test("The advertised mach service is the one AeolusXPC names, and it is enabled")
    func machServicesAdvertisesTheXPCServiceName() throws {
        let plist = try loadPlist()
        let services = try #require(plist["MachServices"] as? [String: Any])
        #expect(services.count == 1, "One daemon, one mach service. Extras are attack surface.")
        #expect(services[AeolusXPCService.machServiceName] as? Bool == true)
    }

    @Test("No legacy SMJobBless keys have crept in")
    func noSMJobBlessKeys() throws {
        let plist = try loadPlist()
        // Mixing the legacy and SMAppService registration schemes produces registration
        // failures whose messages do not point at the cause. Client authorisation is done
        // in code against a code-signing requirement instead — see ADR 0005.
        #expect(plist["SMAuthorizedClients"] == nil)
        #expect(plist["SMPrivilegedExecutables"] == nil)
    }

    @Test("The plist declares no program path that could bypass BundleProgram")
    func noAbsoluteProgramKeys() throws {
        let plist = try loadPlist()
        // `Program`/`ProgramArguments` would let the daemon run something other than the
        // executable inside the bundle — which is the whole basis of "deleting the app
        // removes the daemon".
        #expect(plist["Program"] == nil)
        #expect(plist["ProgramArguments"] == nil)
    }

    @Test("RECOVERY.md's manual escape names the label this daemon actually registers")
    func recoveryDocumentBootsOutTheRightLabel() throws {
        // docs/RECOVERY.md promises `sudo launchctl bootout system/<label>` as the escape
        // that works when nothing else does. It is a promise made to someone whose fans
        // are stuck, typed from a phone, and it fails silently against the wrong label —
        // launchctl reports no such service and the daemon keeps running. Renaming the
        // job without updating the document has to fail here instead.
        let recovery = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("docs/RECOVERY.md"),
            encoding: .utf8)
        let expected = "sudo launchctl bootout system/\(AeolusXPCService.machServiceName)"

        #expect(recovery.contains(expected))
        let plist = try loadPlist()
        #expect(plist["Label"] as? String == AeolusXPCService.machServiceName)
    }
}
