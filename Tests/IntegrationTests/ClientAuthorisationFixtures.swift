import Foundation
import Security
import Testing

@testable import AeolusXPC

/// Shared fixtures for the client authorisation suites (E2.2).
enum ClientAuthorisationFixtures {

    /// A Team ID shaped like Apple's, belonging to nobody.
    static let team = "ABCDE12345"

    /// Both variants, so a variant added later is covered by every parameterised test
    /// rather than silently skipped by a hand-written pair.
    static let variants = ClientRequirementVariant.allCases
}
