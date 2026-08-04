import FanKit

extension AeolusXPCFault {

    /// The refusal a failed bounds check produces.
    ///
    /// One conversion, in one place, so the wire's answer and the model's answer cannot
    /// drift: `FanBoundsImplausibility` says which check failed, this carries it across as
    /// the fault's `detail`, and `FanBoundsImplausibility.manualControlAvailability` says
    /// the same thing in the snapshot's vocabulary. A call site writing its own detail
    /// string would be a second description of the same condition, free to disagree with
    /// the first.
    ///
    /// The detail is helper-authored — it comes from this project's own vocabulary, not
    /// from anything a client sent — so nothing here can steer a root daemon's log line.
    ///
    /// - Parameters:
    ///   - fanIndex: The fan that was refused.
    ///   - implausibility: Which check its declared bounds failed.
    /// - Returns: The refusal to send, carrying the gate's own description as its detail.
    public static func boundsImplausible(
        fanIndex: Int,
        implausibility: FanBoundsImplausibility
    ) -> AeolusXPCFault {
        .boundsImplausible(fanIndex: fanIndex, detail: implausibility.description)
    }
}
