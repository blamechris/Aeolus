import Foundation
import Testing

/// The access an `extension` of `HelperClient` gives every member inside it
/// ([#604](https://github.com/blamechris/Aeolus/issues/604)).
///
/// `HelperClientAccessTests` pins each non-private member as spelled, which closes a widening
/// written on the member's own line or the one above it. It cannot see one written on the block:
/// `public extension HelperClient {` is `public` for every member inside, and each member's line
/// reads as it did. Measured: that edit on `HelperClient+Translation.swift` made `translate`
/// callable from the app and `fanctl` and left the access and seam suites green, and `swift
/// format lint --recursive --strict` exit 0. So the headers are pinned here, as written.
///
/// The two extensions are the verbs, and the translation of the transport's failures. A third is
/// `HelperClientAccessTests.theScannedFilesAreEveryFileTheClientIsIn`'s to notice, and this test
/// is what says how it may be written.
@Suite("An extension of the XPC client widens nothing for the members inside it")
struct HelperClientExtensionAccessTests {

    /// Every `extension HelperClient` in `AeolusXPCClient`, as `MemberAccessScan.extensionHeaders`
    /// reads it. A conformance in another target (`extension HelperClient:
    /// HelperLeaseControlling`) is outside this one and cannot reach what is not `public`.
    private static let headers = [
        "HelperClient+Translation.swift: extension HelperClient {",
        "HelperClientVerbs.swift: extension HelperClient {",
    ]

    /// **Mutation:** write `public extension HelperClient {` at the top of
    /// `HelperClient+Translation.swift`. Run: red here alone, naming the header. **Mutation:**
    /// put `public` alone on the line above `extension HelperClient {`. Run: red here alone.
    @Test("Every extension of the XPC client is written without a modifier")
    func everyExtensionOfTheClientIsBare() throws {
        let found = try MemberAccessScan.extensionHeaders(
            of: "HelperClient", inTarget: "AeolusXPCClient")

        #expect(
            found == Self.headers,
            """
            the extensions of HelperClient changed: found \(found), expected \(Self.headers). A \
            modifier on an extension is the access of every member inside it and is on none of \
            their lines, so `public extension` widens the whole block past what \
            `HelperClientAccessTests` pins. Keep the header bare, with any comment on the line \
            above; a real modifier is a widening to review, and is re-stated here.
            """
        )
    }
}
