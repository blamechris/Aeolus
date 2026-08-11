import AeolusXPC
import ArgumentParser
import Testing

@testable import fanctl

/// `--version` and shell completions — see issue #47. `--version` never opens a
/// connection or negotiates with a running helper: `AeolusXPCVersion.current` is read as
/// the plain `public` constant it is, and every assertion below is against that same
/// pattern, not against any live process.
@Suite("fanctl — --version")
struct FanctlVersionTests {

    @Test("--version reports fanctl's own tool version")
    func versionReportsToolVersion() {
        #expect(Fanctl.versionDescription.contains(Fanctl.toolVersion))
    }

    @Test("--version reports the XPC protocol version, phrased as supported, not negotiated")
    func versionReportsProtocolVersionAsSupported() {
        let description = Fanctl.versionDescription
        #expect(description.contains("protocol version \(AeolusXPCVersion.current)"))
        #expect(description.contains("supports"))
        // Never implies a live, negotiated connection to a running helper — fanctl's read
        // commands never contact one at all (see FanctlCommand.swift's documentation).
        #expect(!description.lowercased().contains("connect"))
        #expect(!description.lowercased().contains("negotiat"))
    }

    @Test("The --version flag itself surfaces the same string swift-argument-parser prints")
    func versionFlagSurfacesTheSameDescription() {
        do {
            _ = try Fanctl.parseAsRoot(["--version"])
            Issue.record("--version is expected to short-circuit parsing, not return a command")
        } catch {
            let message = Fanctl.message(for: error)
            #expect(message == Fanctl.versionDescription)
        }
    }
}

/// `swift-argument-parser` generates these once the command tree is stable
/// (`--generate-completion-script`) — see issue #47. Exercised via the public
/// `completionScript(for:)` API rather than shelling out to the built binary, so this
/// stays a fast, deterministic unit test and fails the moment a subcommand is renamed or
/// dropped without the completions being regenerated to match.
@Suite("fanctl — shell completions")
struct FanctlCompletionScriptTests {

    @Test(
        "A non-empty completion script is generated for every supported shell",
        arguments: CompletionShell.allCases
    )
    func completionScriptIsGenerated(_ shell: CompletionShell) {
        #expect(!Fanctl.completionScript(for: shell).isEmpty)
    }

    @Test(
        "Every top-level subcommand is named in each shell's completion script",
        arguments: CompletionShell.allCases
    )
    func completionScriptMentionsEverySubcommand(_ shell: CompletionShell) {
        let script = Fanctl.completionScript(for: shell)
        for subcommand in ["list", "sensors", "watch", "reset", "dump"] {
            #expect(script.contains(subcommand), "\(shell) completions missing '\(subcommand)'")
        }
    }
}
