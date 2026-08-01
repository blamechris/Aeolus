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

    @Test("The daemon is launched on demand and never kept alive")
    func noBootLaunchOrRestartPolicy() throws {
        let plist = try loadPlist()
        // `KeepAlive = { SuccessfulExit = false }` restarts a job in the *inverse*
        // condition — whenever it exits non-zero — and launchd.plist(5) records that the
        // key also implies `RunAtLoad`. The helper is still a scaffold that exits
        // non-zero on purpose, so those two keys would convert its refusal to run into a
        // root process restarted on launchd's throttle forever, at approval time and at
        // every boot, while `SMAppService.Status` reported `.enabled` the whole time.
        //
        // `MachServices` alone gives on-demand launch, which is all E2 needs. When #72
        // makes this a real daemon, a restart policy has to be argued for against the
        // lease semantics E5 implements — and re-adding either key has to be a decision
        // someone takes deliberately, which means failing here first.
        #expect(plist["RunAtLoad"] == nil)
        #expect(plist["KeepAlive"] == nil)
    }

    @Test("Every `launchctl bootout` in RECOVERY.md names the label this daemon registers")
    func recoveryDocumentBootsOutTheRightLabel() throws {
        // docs/RECOVERY.md promises `sudo launchctl bootout system/<label>` as the escape
        // that works when nothing else does. It is a promise made to someone whose fans
        // are stuck, typed from a phone, and it fails silently against the wrong label —
        // launchctl reports no such service and the daemon keeps running.
        //
        // The document carries the command twice, in §4 ("Stop the helper") and §5
        // ("Remove Aeolus entirely"), and §5's variant redirects stderr to /dev/null. So
        // "at least one occurrence is right" is not the property worth asserting: a
        // rename that updated §4 and missed §5 would leave a user in the worst state
        // running a command that silently does nothing, and then deleting the app while
        // the daemon is still running. Every occurrence has to name the label.
        let recovery = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("docs/RECOVERY.md"),
            encoding: .utf8)

        let afterCommand = recovery.components(separatedBy: "launchctl bootout").dropFirst()
        #expect(
            afterCommand.count >= 2,
            """
            RECOVERY.md documents `launchctl bootout` in both §4 and §5; found \
            \(afterCommand.count). If a section was removed, remove this expectation \
            deliberately rather than weakening it.
            """)

        for tail in afterCommand {
            let unindented = tail.drop(while: { $0 == " " || $0 == "\t" })
            let target = String(unindented.prefix(while: { !$0.isWhitespace }))
            #expect(
                target == "system/\(AeolusXPCService.machServiceName)",
                """
                A `launchctl bootout` in RECOVERY.md targets '\(target)', but the daemon \
                registers as '\(AeolusXPCService.machServiceName)'.
                """)
        }

        let plist = try loadPlist()
        #expect(plist["Label"] as? String == AeolusXPCService.machServiceName)
    }
}
