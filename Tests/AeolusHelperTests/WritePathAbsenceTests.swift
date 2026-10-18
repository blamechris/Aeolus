import Foundation
import Testing

@testable import AeolusHelper

/// The helper's strongest safety property on this branch is structural: **it cannot fail
/// open into a write, because nothing in it reaches one.**
///
/// `SMCConnection.write(_:to:)` has a body on `e4/bring-up`: one `WRITE_BYTES` round trip.
/// The helper calls it in one place, the daemon's `private` forwarder (`DaemonWriteChannel`),
/// and nothing calls the forwarder: no plane-to-channel invocation exists, and the plane
/// answers `.notBuilt`. So what is asserted here is where the write may be named and which
/// command codes exist, not that no write exists anywhere.
///
/// That is a property of the source tree, not of a code path, so it is asserted against
/// the source tree. Reading the files via `#filePath` rather than a test-bundle resource
/// for the same reason `LaunchDaemonPlistTests` does: the point is to check the artefact
/// that actually ships.
///
/// This is a tripwire, not a proof. It cannot see a write reached by arithmetic on a
/// selector, and it is not trying to — what it catches is the realistic regression: a
/// second command constant nobody reviewed, or a helper file that starts calling the write.
/// The real guard is that `SMCConnection.write(_:to:)` stays behind the `FanWrite` SPI group,
/// and that the helper calls it only in the daemon's forwarder, which nothing invokes.
/// `WriteSeamAccessTests` guards the access level itself; this suite guards the calls.
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
    /// `SMCConnection.write(_:to:)` alone uses, and which the helper reaches only through the
    /// daemon's forwarder, invoked by nothing (the test below). Any other code is a command
    /// nobody reviewed.
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

    /// The write channel's protocol, which declares the requirement.
    static let writeChannelDeclaration = "SMCWriteChannel.swift"

    /// `main`'s file, where `DaemonWriteChannel` declares the forwarder and makes the one call.
    static let daemonChannelFile = "AeolusHelperMain.swift"

    /// The helper names `SMCConnection.write(_:to:)` in exactly three files, each in one way, and
    /// calls it in exactly one place (ADR 0014's B1 seam amendment).
    ///
    /// Comments are dropped first — block comments, so `write /* c */ (…)` is the call it is, and
    /// whole `//` lines, so the prose explaining a rule does not trip it. **String literals are
    /// kept**: a call inside `"\(…)"` is a call, and a mention in prose fails loudly and gets
    /// reworded. Backticks are dropped, because `` `write`(bytes, to: key) `` is the same call.
    ///
    /// Three kinds of occurrence are told apart:
    /// - a **reference**, `write(` followed by a compound name's label placeholders —
    ///   `.write(_:to:)` — in the probe and nowhere else;
    /// - a **declaration**, `func write(` — exactly one inside `protocol SMCWriteChannel`, and one
    ///   inside `DaemonWriteChannel`;
    /// - a **use**, anything else — a call, or `.write` taken as a value — exactly one, inside
    ///   `DaemonWriteChannel`'s `func write` body. The write turns will add theirs in their own
    ///   file; B1 builds none.
    @Test("The helper calls the SMC write once, in the daemon's forwarder, and declares it twice")
    func helperNeverCallsWrite() throws {
        let helperSources = try Self.swiftFiles().filter {
            $0.pathComponents.contains("AeolusHelper")
        }
        #expect(!helperSources.isEmpty, "the helper's sources were not found")

        var mentioning: [String] = []
        var declared: [String] = []
        var used: [String] = []
        for file in helperSources {
            let name = file.lastPathComponent
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
                .replacingOccurrences(of: "`", with: "")

            // A bare `write` taken as a value is read in code with comments and strings gone,
            // where prose cannot pass for one (B5).
            let prose = WriteSeamTestIsolationTests.strippingStringLiterals(
                SeamScanner.strippingAllComments(code))
            for at in try Self.bareWriteUses(in: prose) {
                let place = "\(name): \(try Self.container(of: at, in: prose))"
                used.append(place)
                #expect(
                    place == "\(Self.daemonChannelFile): DaemonWriteChannel.write's body",
                    "\(place) takes the write as a bare value; only DaemonWriteChannel may use it"
                )
            }

            let occurrences = try Self.writeOccurrences(in: code)
            guard !occurrences.isEmpty else { continue }
            mentioning.append(name)

            for (occurrence, at) in occurrences {
                let place = "\(name): \(try Self.container(of: at, in: code))"
                switch occurrence {
                case .declaration:
                    declared.append(place)
                case .reference:
                    #expect(
                        name == Self.writeSeamProbe,
                        """
                        \(name) names the SMC write API. Only \(Self.writeSeamProbe) may, and only \
                        as a reference — see docs/ADR/0008-write-authorisation.md.
                        """)
                case .use(let shape):
                    used.append(place)
                    #expect(
                        place == "\(Self.daemonChannelFile): DaemonWriteChannel.write's body",
                        """
                        \(place) uses the write — write\(shape). Only DaemonWriteChannel's \
                        forwarder may, and B1 builds no write turn.
                        """)
                }
            }
        }

        // Coverage, every half: an enumerator that found nothing, or a scan that stopped
        // recognising the name, would make zero assertions above and report the tree clean.
        let expected = [Self.daemonChannelFile, Self.writeChannelDeclaration, Self.writeSeamProbe]
        #expect(
            mentioning.sorted() == expected.sorted(),
            """
            Expected exactly \(expected.sorted()) to name the SMC write; found \
            \(mentioning.sorted()). If the probe is gone, nothing proves the Xcode helper target \
            can still reach the seam.
            """)
        #expect(
            declared.sorted() == [
                "\(Self.daemonChannelFile): DaemonWriteChannel",
                "\(Self.writeChannelDeclaration): protocol SMCWriteChannel",
            ],
            """
            The helper declares the write at \(declared.sorted()): it is declared once in \
            protocol SMCWriteChannel and once in DaemonWriteChannel.
            """)
        #expect(
            used == ["\(Self.daemonChannelFile): DaemonWriteChannel.write's body"],
            "The helper uses the write at \(used), not once, in DaemonWriteChannel's forwarder")
    }

    /// Nothing under `Sources/AeolusHelper` declares an extension of `SMCConnection` — in any form,
    /// empty or populated, `SMCConnection` or `SMCCore.SMCConnection` (ADR 0014's B1 seam
    /// amendment, which reverses ADR 0008's permission for an empty one).
    ///
    /// #226's review is why a populated one was forbidden: inside it, `self` is the actor and an
    /// unqualified `write(bytes, to: key)` is a real write. #436's is why an empty one is too: an
    /// empty conformance to a protocol whose requirement the SPI member witnesses makes the write
    /// callable from every `@testable` test, and inside `extension SMCCore.SMCConnection` a bound
    /// `let submit = write` resolved through it. The plane's recycler is a forwarding struct,
    /// `SMCConnectionRecycler`, so the rule has no exception.
    @Test("No helper file extends SMCConnection, in any form")
    func noHelperFileOpensSMCConnectionsIsolation() throws {
        let helperSources = try Self.swiftFiles().filter {
            $0.pathComponents.contains("AeolusHelper")
        }
        var read: [String] = []
        for file in helperSources {
            read.append(file.lastPathComponent)
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let extensions = try Self.smcConnectionExtensions(in: code)
            #expect(
                extensions == 0,
                """
                \(file.lastPathComponent) declares an extension of SMCConnection. Any \
                conformance or member there can hand the SPI write to a file without the FanWrite \
                opt-in — see docs/ADR/0014-apple-silicon-unlock.md's B1 seam amendment.
                """)
        }

        // Coverage: the files that once held the two extensions must be among those read, and the
        // matcher must see every spelling (`WriteChannelSeamScannerTests`' sibling below).
        #expect(
            Set(read).isSuperset(of: ["SMCFanControlPlane.swift", Self.writeChannelDeclaration]),
            "the scan read \(read.count) helper files and missed the two it must read")
        for spelling in [
            "extension SMCConnection {}", "extension SMCConnection: P {}",
            "extension SMCCore.SMCConnection {}", "extension\n  SMCCore . SMCConnection where X {",
        ] {
            #expect(try Self.smcConnectionExtensions(in: spelling) == 1, "\(spelling)")
        }
        #expect(try Self.smcConnectionExtensions(in: "extension SMCConnectionRecycling {}") == 0)
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

    /// How many `extension SMCConnection` declarations `code` makes, with or without the module
    /// qualifier and with any whitespace between the words — and only that name:
    /// `SMCConnectionRecycling` is a different type.
    static func smcConnectionExtensions(in code: String) throws -> Int {
        try NSRegularExpression(
            pattern:
                #"(?<![A-Za-z0-9_])extension\s+(?:SMCCore\s*\.\s*)?SMCConnection(?![A-Za-z0-9_])"#
        )
        .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }
}
