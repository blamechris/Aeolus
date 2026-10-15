import Foundation
import ImageIO
import Testing

/// The part of an `.appiconset`'s `Contents.json` these tests read: one entry per slot.
struct IconSetContents: Decodable {
    struct Entry: Decodable {
        let filename: String?
        let idiom: String
        let scale: String
        let size: String
    }

    let images: [Entry]
}

/// Guards the shipped app icon: that the asset catalog declares every size macOS asks for,
/// that each file is really the pixel size its slot claims, and that `project.yml` still
/// points the app target at the catalog.
///
/// None of this needs the Xcode build to notice — which is the point. CI's Monitor build
/// compiles the catalog, but `actool` is forgiving: a slot whose file is the wrong size, or
/// absent, produces a warning and an icon that is blurry or missing at that size, not a red
/// build. These checks make those a failure here, in `swift test`.
@Suite("The app icon catalog")
struct AppIconCatalogTests {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AppIconTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    static var iconSet: URL {
        repositoryRoot.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
    }

    /// One size macOS asks an app icon for: a point size at a scale.
    struct Slot: Sendable, CustomTestStringConvertible {
        let points: Int
        let scale: Int

        var pixels: Int { points * scale }
        var size: String { "\(points)x\(points)" }
        var testDescription: String { "\(points)pt @\(scale)x" }
    }

    /// The ten slots of a macOS app icon: 16, 32, 128, 256 and 512 points, at 1x and 2x.
    static let requiredSlots: [Slot] = [16, 32, 128, 256, 512].flatMap { points in
        [1, 2].map { Slot(points: points, scale: $0) }
    }

    static func contents() throws -> IconSetContents {
        let data = try Data(contentsOf: iconSet.appendingPathComponent("Contents.json"))
        return try JSONDecoder().decode(IconSetContents.self, from: data)
    }

    @Test("Contents.json declares exactly the ten macOS slots, each once")
    func contentsDeclaresEveryMacOSSlot() throws {
        let images = try Self.contents().images
        let declared = images.map { "\($0.idiom) \($0.size) \($0.scale)" }
        let required = Self.requiredSlots.map { "mac \($0.size) \($0.scale)x" }

        #expect(Set(declared) == Set(required))
        #expect(declared.count == required.count, "a slot is declared twice")
        #expect(images.allSatisfy { $0.filename != nil }, "a slot names no file")
    }

    @Test(
        "each slot's file is a PNG at exactly the pixel size its slot asks for, with alpha",
        arguments: requiredSlots)
    func fileMatchesItsSlot(_ slot: Slot) throws {
        let images = try Self.contents().images
        let entry = try #require(
            images.first { $0.size == slot.size && $0.scale == "\(slot.scale)x" },
            "no slot declared for \(slot.testDescription)")
        let name = try #require(entry.filename)
        let url = Self.iconSet.appendingPathComponent(name)

        let source = try #require(
            CGImageSourceCreateWithURL(url as CFURL, nil), "\(name) is missing or unreadable")
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])

        #expect(CGImageSourceGetType(source) as String? == "public.png", "\(name) is not a PNG")
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == slot.pixels, "\(name) width")
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == slot.pixels, "\(name) height")
        // The tile's corners and its shadow are transparent. An opaque icon would render as
        // a hard square in the Dock.
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool == true, "\(name) has no alpha")
    }

    /// `project.yml` is read as text, with comment lines dropped so a sentence about the
    /// setting cannot stand in for the setting itself.
    @Test("project.yml points the app target at the catalog and names the icon")
    func projectWiresTheCatalog() throws {
        let manifest = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8)
        let configuration =
            manifest
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        #expect(configuration.contains("- path: Resources/Assets.xcassets"))
        #expect(configuration.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"))
    }

    /// `Sources/Aeolus` is also the `AeolusUI` SwiftPM target's directory, and SwiftPM treats
    /// an `.xcassets` inside a target as that target's resource — measured, it produces a
    /// `<package>_<target>.bundle` — so a catalog placed there would make `swift build`
    /// start needing the asset compiler for something only the app bundle uses. The catalog
    /// lives under `Resources/` for that reason; this keeps it from drifting back.
    @Test("no asset catalog sits inside a SwiftPM target under Sources/")
    func noCatalogUnderSources() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let catalogs = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "xcassets"
        }
        #expect(catalogs.isEmpty, "found \(catalogs.map(\.path)); keep catalogs under Resources/")
    }
}
