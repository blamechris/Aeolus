import Foundation
import Testing

@testable import AeolusXPC

// Shared by every validation suite — request, lease identifier, and handshake. They assert
// the same thing in three places: not that something was refused, but that the guard aimed
// at was the one that refused it.

/// Returns the fault a body threw, or `nil` if it threw something else or nothing.
func fault(from body: () throws -> Void) -> AeolusXPCFault? {
    do {
        try body()
        return nil
    } catch let fault as AeolusXPCFault {
        return fault
    } catch {
        return nil
    }
}

/// The name of the parameter a body's refusal blamed, or `nil` if it did not refuse or
/// refused for some other reason. Asserting on the *name* is what makes these tests able
/// to fail: "something threw" passes just as happily when an unrelated earlier guard
/// fires, which is how a check ends up looking tested while never being reached.
func refusedParameter(_ body: () throws -> Void) -> String? {
    guard case .invalidParameter(let name, _)? = fault(from: body) else { return nil }
    return name
}

/// The detail a body's refusal gave, or `nil` if it did not refuse that way.
///
/// The name alone cannot tell two guards on the same parameter apart. `validateTimeToLive`
/// blames `timeToLive` both for a non-finite value and for an out-of-range one, so a test
/// asserting only the name passes just as happily when the guard it was aimed at has been
/// deleted and a later one caught the value by accident — which is exactly the state a
/// finiteness check is one refactor away from. Where *which* guard fired is the point,
/// assert the detail as well as the name.
func refusedDetail(_ body: () throws -> Void) -> String? {
    guard case .invalidParameter(_, let detail)? = fault(from: body) else { return nil }
    return detail
}
