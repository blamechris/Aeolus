import Foundation
import Testing

@testable import AeolusHelper

/// The helper's strongest safety property on this branch is structural: **it cannot fail
/// open into a write, because nothing in it calls one.**
///
/// `SMCConnection.write(_:to:)` has a body on `e4/bring-up`: one `WRITE_BYTES` round trip.
/// The helper's write path is still not built — no helper file calls that body, and the
/// plane answers `.notBuilt` — so what is asserted here is where the write may be named and
/// which command codes exist, not that no write exists anywhere.
///
/// That is a property of the source tree, not of a code path, so it is asserted against
/// the source tree. Reading the files via `#filePath` rather than a test-bundle resource
/// for the same reason `LaunchDaemonPlistTests` does: the point is to check the artefact
/// that actually ships.
///
/// This is a tripwire, not a proof. It cannot see a write reached by arithmetic on a
/// selector, and it is not trying to — what it catches is the realistic regression: a
/// second command constant nobody reviewed, or a helper file that starts calling the write.
/// The real guard is that `SMCConnection.write(_:to:)` stays behind the `FanWrite` SPI group
/// and that the helper does not call it. `WriteSeamAccessTests` guards the access level
/// itself; this suite guards the calls.
@Suite("The helper has no write path in this tree")
struct WritePathAbsenceTests {

    /// The enumerator lives in `SeamScanner` now, so this suite and
    /// `WriteAuthorisationTests` cannot disagree about which files count as the source tree.
    /// It also carries the non-empty guard that used to be on only one of the two tests here.
    private static func swiftFiles() throws -> [URL] {
        try SeamScanner.swiftFiles()
    }

    /// The SMC's command codes this tree may declare are the three reads — 5 (`READ_BYTES`),
    /// 8 (`READ_INDEX`), 9 (`READ_KEYINFO`) — and the one write, 6 (`WRITE_BYTES`), which
    /// `SMCConnection.write(_:to:)` alone uses and which nothing in the helper calls (the test
    /// below). Any other code is a command nobody reviewed.
    ///
    /// This is a **coverage pin**, not only an allowlist. The declared codes must be exactly
    /// `[5, 6, 8, 9]`, each once: an unknown code fails, a second `6` fails, and so does the
    /// write's constant disappearing from the scan — the shape of a selector written inline
    /// as a literal, which an allowlist alone reports as clean.
    @Test("Sources declares exactly the SMC selectors 5, 6, 8 and 9, and one write selector")
    func theSelectorConstantsAreTheThreeReadsAndOneWrite() throws {
        let allowed: Set<String> = ["5", "6", "8", "9"]
        let pattern = try NSRegularExpression(
            pattern: #"selector[A-Za-z]*\s*:\s*UInt8\s*=\s*(\d+)"#)

        // Without this, a `sourcesRoot` that resolved wrongly would enumerate nothing, the
        // loop below would make zero assertions, and the strongest safety property in the
        // project would be asserted by a green test that checked no files at all. Its
        // sibling `helperNeverCallsWrite` has always had the equivalent line.
        let files = try Self.swiftFiles()
        #expect(!files.isEmpty, "the project's sources were not found")

        var declared: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[valueRange])
                declared.append(value)
                #expect(
                    allowed.contains(value),
                    """
                    \(file.lastPathComponent) declares SMC selector \(value). The commands \
                    are 5, 8 and 9 (reads) and 6 (the write); anything else is a command \
                    nobody reviewed.
                    """
                )
            }
        }

        #expect(
            declared.sorted() == ["5", "6", "8", "9"],
            """
            Sources declares the SMC selectors \(declared.sorted()), not exactly \
            ["5", "6", "8", "9"]. There is one write selector, 6, declared once in \
            SMCConnection.swift; a missing one means the write's code is no longer where \
            this scan can see it, and a duplicate is a second write.
            """
        )
    }

    /// The one file permitted to *name* the write seam. Everything else in the helper may
    /// not contain the text `write(` at all.
    ///
    /// #160 gave the helper a reachability probe, because `@_spi(FanWrite) public`
    /// replaced `package` on `SMCConnection.write(_:to:)` and an access level is only
    /// proven by a reference the compiler must resolve. That reference is written as a
    /// compound name — `connection.write(_:to:)` — so the file contains the text this test
    /// used to forbid outright. Naming the exception rather than deleting the rule is the
    /// point: one file, by name, with zero calls in it.
    static let writeSeamProbe = "WriteSeamReachability.swift"

    /// The one file permitted to *declare* the name: the write channel's protocol, whose
    /// requirement `SMCConnection.write(_:to:)` witnesses through an empty extension (ADR 0014's
    /// B1 amendment, "the seam is the helper's").
    static let writeChannelDeclaration = "SMCWriteChannel.swift"

    /// The helper is the only thing that could reach `SMCConnection.write(_:to:)`, and it
    /// never calls it. It names the write in exactly two places: the probe's reference, and
    /// the write channel's one requirement.
    ///
    /// Comment lines are dropped before the scan, which is not a detail: this file's first
    /// green run failed on `AeolusHelperMain`'s own documentation explaining that
    /// `SMCConnection.write(_:to:)` was `package`-scoped and still throws. A tripwire that
    /// fires on the sentence saying the thing does not exist is a tripwire nobody keeps.
    /// The trade is that a call hidden after code on a commented line is not seen — which
    /// is a contrived case, where an added write is not. Backticks are dropped too, because
    /// `` `write`(bytes, to: key) `` is the same call.
    ///
    /// Three kinds of occurrence are told apart, because the tree has to make two of them
    /// without making the third:
    /// - a **reference**, `write(` followed by a compound name's label placeholders —
    ///   `.write(_:to:)` — permitted in the probe and nowhere else;
    /// - a **declaration**, `func write(` — permitted once, as the requirement inside
    ///   `protocol SMCWriteChannel`, and nowhere else;
    /// - a **call**, anything else — `.write(bytes, to: key)`, `write()`, an unqualified
    ///   `write(bytes, to: key)` — permitted nowhere. B1 builds no write turn.
    @Test("The helper never calls the SMC write API, and declares it once, in the channel")
    func helperNeverCallsWrite() throws {
        let helperSources = try Self.swiftFiles().filter {
            $0.pathComponents.contains("AeolusHelper")
        }
        #expect(!helperSources.isEmpty, "the helper's sources were not found")

        var mentioning: [String] = []
        var declaring: [String] = []
        for file in helperSources {
            let name = file.lastPathComponent
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
                .replacingOccurrences(of: "`", with: "")

            let occurrences = try Self.writeOccurrences(in: code)
            guard !occurrences.isEmpty else { continue }
            mentioning.append(name)

            for occurrence in occurrences {
                if occurrence == .declaration { declaring.append(name) }
                Self.judge(occurrence, in: name)
            }
        }

        // Coverage, both halves. Without it, an enumerator that found nothing — or a scan that
        // stopped recognising `write(` — would make zero assertions above and report the tree
        // clean. The probe and the channel are the two files guaranteed to be seen, and the
        // channel's one requirement is the one declaration.
        #expect(
            mentioning.sorted() == [Self.writeChannelDeclaration, Self.writeSeamProbe].sorted(),
            """
            Expected exactly \(Self.writeSeamProbe) and \(Self.writeChannelDeclaration) to name \
            the SMC write API; found \(mentioning.sorted()). If the probe is gone, nothing proves \
            the Xcode helper target can still reach the write seam.
            """
        )
        #expect(
            declaring == [Self.writeChannelDeclaration],
            """
            The helper declares the write \(declaring.count) times, in \(declaring). It is \
            declared once, as SMCWriteChannel's requirement.
            """)
        #expect(
            try Self.channelProtocolDeclaresTheWrite(),
            """
            \(Self.writeChannelDeclaration) declares the write outside `protocol \
            SMCWriteChannel`. The one declaration the helper may make is that requirement.
            """)
    }

    /// Nothing under `Sources/AeolusHelper` may declare a *populated* `extension
    /// SMCConnection`.
    ///
    /// This is the shape guard behind the scan above, and #226's review is why it exists.
    /// Inside an extension of the actor, `self` is an `SMCConnection`, so `write(bytes, to:
    /// key)` — no receiver, no dot — is a real SMC write. `WriteSeamReachability` was such
    /// an extension when the PR was reviewed; a mutation inserting that call compiled and
    /// left every control green, because the scan was looking for `.write(`.
    ///
    /// The scan is now widened, so this is belt *and* braces — deliberately. The widened
    /// scan is text matching and can be evaded by spelling; the isolation cannot be opened
    /// at all without the declaration this test forbids, which is the structural half.
    ///
    /// An **empty** extension is permitted, and is the form `SMCFanControlPlane.swift`'s
    /// `extension SMCConnection: SMCConnectionRecycling {}` takes, and `SMCWriteChannel.swift`'s
    /// `extension SMCConnection: SMCWriteChannel {}`. A conformance that declares no member puts
    /// no unqualified name in scope, so it cannot host the call this test is about — and the
    /// second of those sits in a file that imports the write SPI, so a member added to it could
    /// write. That is a property of the declaration, checked here, rather than a file allowlist
    /// that another such extension would slip past.
    @Test("No helper file opens SMCConnection's isolation")
    func noHelperFileOpensSMCConnectionsIsolation() throws {
        let helperSources = try Self.swiftFiles().filter {
            $0.pathComponents.contains("AeolusHelper")
        }
        #expect(!helperSources.isEmpty, "the helper's sources were not found")

        var extending: [String] = []
        for file in helperSources {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            for body in try Self.smcConnectionExtensionBodies(in: code) {
                extending.append(file.lastPathComponent)
                #expect(
                    body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    """
                    \(file.lastPathComponent) declares a populated extension of \
                    SMCConnection. Inside one, `self` is the actor and an unqualified \
                    write(bytes, to: key) is a live SMC write — see \
                    docs/ADR/0008-write-authorisation.md. Only an empty conformance \
                    extension is permitted.
                    """
                )
            }
        }

        // Coverage, not decoration. The helper has two such extensions today — the empty
        // `SMCConnectionRecycling` and `SMCWriteChannel` conformances — so a scan that stopped
        // recognising the declaration, or an enumerator that found nothing, would leave the loop
        // making zero assertions and this test green over a tree that had reopened the
        // isolation. Both are named, so a scan that found only one is not reading the tree.
        let known: Set<String> = ["SMCFanControlPlane.swift", Self.writeChannelDeclaration]
        #expect(
            Set(extending).isSuperset(of: known),
            """
            The extensions of SMCConnection found under Sources/AeolusHelper are in \
            \(extending.sorted()), not in every one of \(known.sorted()). The empty conformances \
            in those files are expected to match, so this scan is not reading the source tree.
            """
        )
    }

    /// The reachability probe contains no call and no effect: no `try`, no `await`, and no
    /// application of the function values it binds.
    ///
    /// #226's delta review found the door D30 left ajar, one indirection later. The probe
    /// binds the seam to a local — `let writeSeam: ([UInt8], SMCKey) throws -> Void =
    /// connection.write(_:to:)` — and `try! writeSeam([0x01], SMCKey("F0Md")!)` on the next
    /// line is a live SMC write that compiles, because an `isolated` parameter puts the body
    /// inside the actor's isolation. `helperNeverCallsWrite` cannot see it: the applied name
    /// is `writeSeam(`, and that scan's lookbehind is on the name `write`.
    ///
    /// The isolated-parameter shape is kept, because there is nowhere else to put the
    /// reference — `SMCConnection.write(_:to:)` cannot be formed as an unbound function
    /// value from a `nonisolated` context (`#ActorIsolatedCall`) — so the *call* door is
    /// closed here instead. Applying any local the probe binds is a failure whatever it is
    /// named, so this does not depend on the two spellings in the file today. `try` and
    /// `await` are forbidden outright rather than only inside a call pattern: both seam
    /// members throw, so no application of either can be written without `try`.
    @Test("The write-seam probe contains no call, no try and no await")
    func theWriteSeamProbeIsInert() throws {
        let probe = try #require(
            try Self.swiftFiles().first { $0.lastPathComponent == Self.writeSeamProbe },
            """
            \(Self.writeSeamProbe) was not found under Sources/; the probe is the only thing \
            proving the Xcode helper target can name the write seam.
            """)
        let code = SeamScanner.strippingComments(
            try String(contentsOf: probe, encoding: .utf8))
        let whole = NSRange(code.startIndex..<code.endIndex, in: code)

        for keyword in ["try", "await"] {
            let effect = try NSRegularExpression(
                pattern: #"(?<![A-Za-z0-9_])"# + keyword + #"(?![A-Za-z0-9_])"#)
            #expect(
                effect.firstMatch(in: code, range: whole) == nil,
                """
                \(Self.writeSeamProbe) contains `\(keyword)`. The probe may name the SMC \
                write seam and must do nothing with it; both seam members throw, so an \
                effect keyword there is a call — see docs/ADR/0008-write-authorisation.md.
                """
            )
        }

        let binding = try NSRegularExpression(pattern: #"(?m)^\s*let\s+([A-Za-z_]\w*)\s*:"#)
        let bound: [String] = binding.matches(in: code, range: whole).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }

        // Coverage, not decoration. A binding scan that stopped matching the form actually
        // written would leave the loop below making zero assertions and report a probe that
        // applies its seam locals as clean. The probe binds one local per seam member, and
        // `WriteSeamAccessTests.smcCoreDeclaresExactlyTwoSPIMembers` pins that there are two.
        #expect(
            bound.count == 2,
            """
            \(Self.writeSeamProbe) binds \(bound.count) seam locals, not 2 \
            (\(bound.joined(separator: ", "))). Either the probe no longer names both SPI \
            members, or this scan is not reading it.
            """
        )

        for name in bound {
            let applied = try NSRegularExpression(
                pattern: #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: name)
                    + #"\s*\("#)
            #expect(
                applied.firstMatch(in: code, range: whole) == nil,
                """
                \(Self.writeSeamProbe) applies `\(name)`, the local it binds the seam to. \
                Naming the seam proves the access level; applying it is a write, and E3/E4 \
                do not exist — see docs/ADR/0008-write-authorisation.md.
                """
            )
        }
    }

    /// Nothing under `Sources/` names the probe but the probe.
    ///
    /// This is what bounds the blast radius of the test above: both probe functions are
    /// unreferenced, so anything smuggled into one is dead code until something calls the
    /// probe. That was a fact when #226 was reviewed; here it becomes a property of the
    /// tree. Comments are stripped, because the probe is discussed in prose —
    /// `SMCConnection`'s own documentation points at it by name, and a tripwire that fires
    /// on the sentence describing the thing is a tripwire nobody keeps.
    @Test("Nothing under Sources references the write-seam reachability probe")
    func nothingOutsideTheProbeNamesIt() throws {
        let names = ["WriteSeamReachability", "namesTheWriteSeam", "namesTheEncodeSeam"]
        var seenInProbe: Set<String> = []

        for file in try Self.swiftFiles() {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            for name in names where code.contains(name) {
                #expect(
                    file.lastPathComponent == Self.writeSeamProbe,
                    """
                    \(file.lastPathComponent) references \(name). The reachability probe \
                    exists only to make the compiler resolve the seam's access level, and \
                    nothing may call it: an unreferenced probe cannot become a write path \
                    however it is edited — see docs/ADR/0008-write-authorisation.md.
                    """
                )
                if file.lastPathComponent == Self.writeSeamProbe { seenInProbe.insert(name) }
            }
        }

        #expect(
            seenInProbe == Set(names),
            """
            \(Self.writeSeamProbe) names \(seenInProbe.sorted()), not \(names.sorted()). \
            Either the probe was renamed — in which case this scan guards nothing — or the \
            enumerator is not reading the source tree.
            """
        )
    }

    /// `extension SMCConnection` matched by name, and only that name —
    /// `SMCConnectionRecycling` is a different type and does not count.
    private static let smcConnectionExtension = try? NSRegularExpression(
        pattern: #"extension\s+SMCConnection(?![A-Za-z0-9_])"#)

    /// The text between the braces of every `extension SMCConnection` in `code`,
    /// brace-balanced rather than stopped at the first `}`.
    private static func smcConnectionExtensionBodies(in code: String) throws -> [String] {
        let pattern = try #require(Self.smcConnectionExtension)
        var bodies: [String] = []

        let whole = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in pattern.matches(in: code, range: whole) {
            guard let matched = Range(match.range, in: code),
                let open = code.range(of: "{", range: matched.upperBound..<code.endIndex)
            else { continue }

            var depth = 1
            var index = open.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1 }
                index = code.index(after: index)
            }
            let close = depth == 0 ? code.index(before: index) : code.endIndex
            bodies.append(String(code[open.upperBound..<close]))
        }
        return bodies
    }
}
