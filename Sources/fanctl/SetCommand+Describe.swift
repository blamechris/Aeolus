import AeolusXPC
import AeolusXPCClient
import Foundation

extension SetCommand {

    /// An error in the words the client chose, for a message about a lease already held: every
    /// failure there is a loss of control whatever its type.
    ///
    /// **Four errors are not quoted.** Their own descriptions go on to say what the helper did
    /// with the fans, or to advise asking for them again, and neither is something `set`
    /// observed (`CLAUDE.md` rule 6) or something a run that never re-acquires has use for:
    /// `leaseExpired` ("the fans have returned to automatic control. Acquire a new lease"),
    /// `helperRestarted` ("any manual control it was holding ended with it; ask for the fans
    /// again"), and `helperNeverAnswered` and `connectionAbandoned` ("ends any manual control it
    /// held; the helper returns those fans to automatic control when it handles that"). What
    /// `set` can say is what it saw, and, where it looked, what the safe-state check then
    /// found.
    static func describe(_ error: any Error) -> String {
        if let fault = error as? AeolusXPCFault, case .leaseExpired = fault {
            return "The helper answered that the manual-control lease had expired."
        }
        if let failure = error as? HelperClientError {
            switch failure {
            case .helperRestarted:
                return
                    "The connection to the helper was interrupted while the request was in flight."
            case .helperNeverAnswered(let deadline):
                return
                    "The helper did not answer within \(deadline), and this copy of fanctl gave "
                    + "up on the connection."
            case .connectionAbandoned:
                return
                    "This copy of fanctl gave up on its connection to the helper before the helper "
                    + "answered the request."
            case .clientCannotVerifyHelper, .helperUnreachable, .helperSignatureRejected,
                .replyNotDelivered, .protocolViolation:
                break
            }
        }
        return HelperCommandFailure(classifying: error, during: .holdingControl).message
    }
}
