import AeolusXPC
import Testing

@testable import fanctl

/// `--version` is issue #47's "reads a public constant, connects to nothing" contract:
/// see `FanctlCommand.swift`'s own documentation on why the wording matters now that ADR
/// 0005 gives the helper a real, connect-time `hello` handshake to be distinct from.
@Suite("Fanctl — --version reports the tool version and the XPC protocol version")
struct FanctlVersionTests {

    @Test("versionDescription names both the tool version and the XPC protocol version")
    func versionDescriptionNamesBothVersions() {
        let description = Fanctl.versionDescription

        #expect(description.contains(Fanctl.toolVersion))
        #expect(description.contains("\(AeolusXPCVersion.current)"))
    }

    @Test("versionDescription is phrased as supported, never as a negotiated connection")
    func versionDescriptionIsNeverPhrasedAsNegotiated() {
        let description = Fanctl.versionDescription

        // The load-bearing distinction: reading AeolusXPCVersion.current is a
        // compile-time fact about this binary, not a live XPC round trip against
        // whatever helper (if any) happens to be installed.
        #expect(description.contains("this build supports"))
        #expect(description.contains("not a negotiated connection"))
    }

    @Test("--version prints exactly versionDescription, not just returns a matching value")
    func parsingVersionFlagSurfacesExactlyVersionDescription() {
        do {
            _ = try Fanctl.parseAsRoot(["--version"])
            Issue.record("expected --version to be handled as a version request")
        } catch {
            #expect(Fanctl.message(for: error) == Fanctl.versionDescription)
            #expect(Fanctl.exitCode(for: error) == .success)
        }
    }

    @Test("A subcommand's own --version still surfaces the shared root version text")
    func subcommandVersionFlagStillSurfacesRootVersion() {
        // Subcommands (List/Sensors/Watch/Dump/Reset) declare no version of their own —
        // swift-argument-parser falls back to the last non-empty version in the command
        // stack, which is Fanctl's. A regression that gave a subcommand its own empty
        // string would silently produce "Unspecified version" instead of this text.
        do {
            _ = try Fanctl.parseAsRoot(["list", "--version"])
            Issue.record("expected --version to be handled as a version request")
        } catch {
            #expect(Fanctl.message(for: error) == Fanctl.versionDescription)
        }
    }
}
