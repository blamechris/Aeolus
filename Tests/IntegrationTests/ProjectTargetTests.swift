import Testing

/// The reader the identifier tripwires share is itself a tripwire, so it gets its own
/// mutation-checkable tests: a reader that quietly returned the first of two declarations
/// would leave every suite built on it green while a configuration shipped a different
/// identifier from the one the helper pins.
///
/// The fixture is the shape that gap takes. `Full Release` is the configuration that ships,
/// and the only one the build in CI never produces, so a per-configuration override there is
/// the override nothing else would notice.
@Suite("project.yml reading — a key is read only if it is declared once")
struct ProjectTargetTests {

    private static let single = """
        targets:
          other:
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.example.other
          # A comment at the targets' indentation ends the region above it.
          tool:
            # PRODUCT_BUNDLE_IDENTIFIER: com.example.commented
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.example.tool
                PRODUCT_BUNDLE_IDENTIFIER_SUFFIX: -nope
          later:
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.example.later
        """

    /// `single`, with a per-configuration override in `tool` — the Codex finding's mutation.
    private static let overridden = """
        targets:
          tool:
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.example.tool
              configs:
                Full Release:
                  PRODUCT_BUNDLE_IDENTIFIER: com.example.tool.release
        """

    /// The same override spelled as a conditional setting, which needs no `configs:` block.
    private static let conditional = """
        targets:
          tool:
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.example.tool
                "PRODUCT_BUNDLE_IDENTIFIER[config=Full Release]": com.example.tool.release
        """

    private static func tool(_ yaml: String) throws -> ProjectTarget {
        try #require(ProjectTarget.slice("tool", from: yaml), "the fixture declares no tool target")
    }

    @Test("A region ends at the next target or at a comment at the targets' indentation")
    func regionIsScopedToItsTarget() throws {
        let target = try Self.tool(Self.single)
        let text = target.lines.joined(separator: "\n")
        #expect(text.contains("com.example.tool"))
        #expect(!text.contains("com.example.other"))
        #expect(!text.contains("com.example.later"))
    }

    @Test("A target the file does not declare is nil, not an empty region that passes")
    func missingTargetIsNil() {
        #expect(ProjectTarget.slice("absent", from: Self.single) == nil)
    }

    @Test("A key declared once is counted once; comments and longer key names are not declarations")
    func singleDeclarationCountsOnce() throws {
        let target = try Self.tool(Self.single)
        #expect(target.declarations(of: "PRODUCT_BUNDLE_IDENTIFIER").count == 1)
        #expect(try target.value(of: "PRODUCT_BUNDLE_IDENTIFIER") == "com.example.tool")
    }

    @Test(
        "A per-configuration restatement is a second declaration",
        arguments: [ProjectTargetTests.overridden, ProjectTargetTests.conditional]
    )
    func restatementIsCounted(yaml: String) throws {
        let target = try Self.tool(yaml)
        #expect(target.declarations(of: "PRODUCT_BUNDLE_IDENTIFIER").count == 2)
    }

    @Test(
        "Reading a key that is declared twice fails the test instead of returning the first",
        arguments: [ProjectTargetTests.overridden, ProjectTargetTests.conditional]
    )
    func doubleDeclarationIsRefused(yaml: String) throws {
        let target = try Self.tool(yaml)
        withKnownIssue("a second declaration of the key must not be read past") {
            _ = try target.value(of: "PRODUCT_BUNDLE_IDENTIFIER")
        }
    }

    @Test("Reading a key the target does not declare fails the test")
    func missingKeyIsRefused() throws {
        let target = try Self.tool(Self.single)
        withKnownIssue("an absent key must not read as an empty value") {
            _ = try target.value(of: "CFBundleIdentifier")
        }
    }
}
