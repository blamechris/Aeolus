import AeolusXPC
import AeolusXPCClient
import Foundation

extension SetCommand {

    /// An error in the words the client chose, for a message about a lease already held: every
    /// failure there is a loss of control whatever its type.
    ///
    /// **One fault is not quoted.** `leaseExpired`'s own description goes on to say the fans
    /// "have returned to automatic control", and nothing here observed that: it is the helper's
    /// claim about what it did, and `CLAUDE.md` rule 6 forbids repeating one as though it were
    /// seen. What `set` can say is what the helper answered, and, where it looked, what the
    /// safe-state check then found. The same description also tells the client to acquire a new
    /// lease, which a run that never re-acquires has no use for.
    static func describe(_ error: any Error) -> String {
        if let fault = error as? AeolusXPCFault, case .leaseExpired = fault {
            return "The helper answered that the manual-control lease had expired."
        }
        return HelperCommandFailure(classifying: error, during: .holdingControl).message
    }
}
