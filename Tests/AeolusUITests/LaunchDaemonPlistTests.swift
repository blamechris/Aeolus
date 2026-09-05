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

    /// Every key this daemon declares, and nothing else.
    ///
    /// The allowlist replaces `noBootLaunchOrRestartPolicy`, which named the two keys
    /// somebody had thought of — `RunAtLoad` and `KeepAlive` — and was therefore blind to
    /// every other way of starting a root process at a time nobody argued for.
    /// [#84](https://github.com/blamechris/Aeolus/issues/84) named `StartInterval` as the
    /// gap; `WatchPaths`, `StartCalendarInterval`, `StartOnMount` and `QueueDirectories` are
    /// the same shape. This is `WriteVerbAllowlistTests`' discipline applied to a plist: a
    /// new key has to be **acknowledged** by whoever adds it, rather than merely spelled
    /// outside a list of prohibitions.
    private static let allowedKeys: Set<String> = [
        "Label",
        "BundleProgram",
        "MachServices",
        "ProcessType",
        "KeepAlive",
        "RunAtLoad",
    ]

    @Test("The plist declares exactly the six keys the restart policy argued for")
    func onlyTheAllowlistedKeysArePresent() throws {
        let plist = try loadPlist()
        let declared = Set(plist.keys)

        let unlisted = declared.subtracting(Self.allowedKeys).sorted()
        #expect(
            unlisted.isEmpty,
            """
            The launch daemon declares \(unlisted), which nothing in ADR 0007 or #103's \
            decision A3 argued for. Every key here starts or restarts a root process, so \
            this is a safety decision: add it to `allowedKeys` deliberately, with the \
            argument, or take it out of the plist.
            """)

        let missing = Self.allowedKeys.subtracting(declared).sorted()
        #expect(
            missing.isEmpty,
            """
            The launch daemon no longer declares \(missing). Losing `KeepAlive` or \
            `RunAtLoad` silently removes the restart half of docs/SAFETY.md § 6's crash \
            coverage — the helper stops being restarted after a SIGKILL, so nothing ever \
            reconciles the fans it died holding.
            """)

        // The count, separately from the two set comparisons above, because a dictionary
        // cannot hold a duplicate key but a *rename* can pass both of them while changing
        // what ships: `allowedKeys` and the plist would agree with each other and disagree
        // with launchd. Six is the number A3 decided.
        #expect(
            plist.count == 6,
            "the launch daemon declares \(plist.count) keys; decision A3 settled on six")
    }

    @Test("KeepAlive restarts the helper only when it exits non-zero")
    func keepAliveIsExactlySuccessfulExitFalse() throws {
        let plist = try loadPlist()
        let keepAlive = try #require(
            plist["KeepAlive"] as? [String: Any],
            """
            `KeepAlive` is not a dictionary. A bare `<true/>` restarts the helper whenever \
            it exits for any reason, including a deliberate orderly teardown — which turns \
            `exit(0)` from "do not restart me" into a request launchd ignores.
            """)

        #expect(
            keepAlive.count == 1,
            "`KeepAlive` carries \(keepAlive.count) conditions; A3 decided on exactly one")
        #expect(
            keepAlive["SuccessfulExit"] as? Bool == false,
            """
            `KeepAlive` is not `{ SuccessfulExit = false }`. That value is what makes the \
            exit code a contract: a teardown that could not restore the fans exits non-zero \
            so launchd restarts the helper and startup reconciliation runs (ADR 0007, \
            docs/SAFETY.md § 6). Any other value breaks the contract in one direction or \
            the other.
            """)
    }

    @Test("RunAtLoad is written explicitly rather than left to KeepAlive's implication")
    func runAtLoadIsExplicitAndTrue() throws {
        let plist = try loadPlist()
        #expect(
            plist["RunAtLoad"] as? Bool == true,
            """
            `RunAtLoad` is not explicitly `true`. launchd.plist(5) records that `KeepAlive` \
            implies it, and #103's decision A3 declines to rest boot-time reconciliation on \
            an implication in a manual page: manual mode persisting across a reboot is the \
            case this key covers, and nobody has verified it cannot happen.
            """)
    }

    /// `exit(0)` is the helper's "do not restart me", so it may exist in exactly one place.
    ///
    /// `KeepAlive = { SuccessfulExit = false }` gives the exit code meaning: non-zero means
    /// launchd restarts the helper and startup reconciliation runs. A zero exit therefore
    /// asserts *"the fans are back on automatic control and nobody needs to check"*, and it
    /// is only ever true of the orderly-teardown path that performed the restore. A second
    /// one — an early return from a failed bring-up, say, or a guard that gives up — would
    /// be a root daemon exiting silently with fans in an unknown mode and nothing scheduled
    /// to look at them.
    ///
    /// **The expected count is 0 today, and it is 0 because the orderly path does not
    /// exist yet.** `AeolusHelperMain` ends in `dispatchMain()` and never returns; the
    /// teardown that restores and then exits is E5.4d's
    /// ([#166](https://github.com/blamechris/Aeolus/issues/166)). That change raises this
    /// number to 1 in the same commit that adds the path, deliberately — which is the whole
    /// point of asserting a count rather than a location.
    @Test("`exit(0)` appears in the helper exactly as many times as a path has argued for")
    func theOrderlyExitIsCountedNotAssumed() throws {
        let helper = Self.repositoryRoot.appendingPathComponent("Sources/AeolusHelper")
        let enumerator = try #require(
            FileManager.default.enumerator(at: helper, includingPropertiesForKeys: nil),
            "Sources/AeolusHelper was not found")

        var occurrences: [String: Int] = [:]
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = source.components(separatedBy: "exit(0)").count - 1
            if count > 0 { occurrences[file.lastPathComponent] = count }
        }

        #expect(
            occurrences.values.reduce(0, +) == 0,
            """
            `exit(0)` occurs in \(occurrences.sorted { $0.key < $1.key }). Under \
            `KeepAlive = { SuccessfulExit = false }` a zero exit tells launchd not to \
            restart the helper, which asserts the fans are back on automatic control. \
            Exactly one path may say that, and E5.4d (#166) is the change that adds it — \
            raise the expected count to 1 there, with the restore in front of it.
            """)
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

        let components = recovery.components(separatedBy: "launchctl bootout")
        let beforeCommand = components.dropLast()
        let afterCommand = components.dropFirst()
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

        // `launchctl bootout` without `sudo` fails with a permissions error rather than
        // silently doing nothing — a milder failure than the wrong-label case above, but
        // still a broken recovery step for someone copying the command verbatim.
        for head in beforeCommand {
            let reversedTail = head.reversed().drop(while: { $0.isWhitespace })
            let precedingWord = reversedTail.prefix(while: { !$0.isWhitespace })
            let precedingToken = String(precedingWord.reversed())
            #expect(
                precedingToken == "sudo",
                """
                A `launchctl bootout` in RECOVERY.md is preceded by '\(precedingToken)' \
                instead of 'sudo'; it needs root to unload a system-domain daemon.
                """)
        }

        let plist = try loadPlist()
        #expect(plist["Label"] as? String == AeolusXPCService.machServiceName)
    }
}
