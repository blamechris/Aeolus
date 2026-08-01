import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// A lease ID is a `UUID` on both sides of the boundary and a bare `String` in between,
/// because that is what an `@objc` signature carries. This suite is where that gap is
/// closed: the same hostile input `holderDescription` is guarded against arrives here
/// through the field nobody thinks of as a string, and the helper logs what it refused.
@Suite("XPC lease identifier validation")
struct XPCLeaseIDValidationTests {

    private func refusedLeaseID(_ id: String) -> String? {
        refusedParameter({ try AeolusXPCValidation.validateLeaseID(id) })
    }

    @Test("A lease ID that is a UUID is accepted, in either case")
    func validLeaseIDIsAccepted() throws {
        try AeolusXPCValidation.validateLeaseID(UUID().uuidString)
        try AeolusXPCValidation.validateLeaseID(UUID().uuidString.lowercased())
    }

    /// A newline here forges a helper log entry; an unbounded string here is an unbounded
    /// write by root. Both are the harms `maxHolderDescriptionUTF8Bytes` and the
    /// control-character guard already close for a display string.
    @Test(
        "A lease ID that is not a canonical UUID is refused",
        arguments: [
            "",
            "   ",
            "not-a-lease-at-all",
            "123e4567-e89b-12d3-a456-42661417400",
            "123e4567-e89b-12d3-a456-4266141740000",
            "{123e4567-e89b-12d3-a456-426614174000}",
            "123e4567-e89b-12d3-a456-426614174000\nroot: granted",
            "123e4567-e89b-12d3-a456-426614174000\u{202E}",
        ]
    )
    func nonUUIDLeaseIDIsRefused(_ id: String) {
        #expect(refusedLeaseID(id) == "leaseID")
    }

    @Test("An unbounded lease ID is refused rather than reaching a log line")
    func overlongLeaseIDIsRefused() {
        #expect(refusedLeaseID(String(repeating: "a", count: 100_000)) == "leaseID")
    }

    /// The case that makes the length check load-bearing rather than decorative.
    /// `UUID(uuidString:)` **accepts** a trailing NUL, parsing it to the same UUID as the
    /// string without one — so a parse-only guard would admit two distinct strings as one
    /// ID, and NUL is exactly the character that truncates a value for anything reading it
    /// as C. Deleting the length check must fail here.
    @Test("A UUID with a trailing NUL is refused, though UUID(uuidString:) parses it")
    func leaseIDWithTrailingNULIsRefused() {
        let smuggled = "123E4567-E89B-12D3-A456-426614174000\u{0}"
        #expect(UUID(uuidString: smuggled) != nil, "the premise of this test no longer holds")
        #expect(refusedLeaseID(smuggled) == "leaseID")
    }
}
