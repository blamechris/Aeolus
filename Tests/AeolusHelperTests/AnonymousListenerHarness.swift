import AeolusXPC
import Foundation

@testable import AeolusHelper
@testable import AeolusXPCClient

/// Applies no code-signing requirement at all.
///
/// **Declared in the test target on purpose, and it must stay there.** `Sources/` contains
/// no `ConnectionAdmission` that skips the requirement, so no production wiring can select
/// one however it is initialised — see `ConnectionAdmission`'s documentation. What this
/// buys is a listener CI can drive with no signing identity, which is the only way the
/// handshake gate gets exercised over a real connection.
///
/// What it therefore does *not* prove: that the production requirement admits the real
/// Aeolus.app and refuses everything else. That needs a Developer ID signature, exists on
/// one machine, and is E2.5's manual checklist. ADR 0005 says so in as many words, and a
/// green run of this file must never be read as evidence the boundary holds.
struct UnenforcedAdmission: ConnectionAdmission {
    func admit(_ connection: NSXPCConnection) -> AdmissionDecision {
        .admitted(teamIdentifier: "TESTONLY")
    }
}

/// Records what the connection looked like at the instant `admit` was called.
///
/// **Why the ordering needs a spy to be testable at all.** `HelperListenerDelegate` applies
/// the code-signing requirement before it configures the connection and before it resumes
/// it, and that ordering is an acceptance criterion. Moving `admission.admit(connection)`
/// below `connection.resume()` leaves every other test in this target green: by the time a
/// client's message arrives the connection is fully wired either way, so the window a
/// reorder opens — a connection resumed before it carries a requirement — is invisible from
/// outside.
///
/// It is visible from *inside* `admit`, where `exportedObject`, `exportedInterface` and
/// `invalidationHandler` are all still `nil` and only there. Those three are what the
/// configuration block sets, so a call that has slipped past it is caught.
///
/// `@unchecked Sendable` over an `NSLock` for the same reason `PendingReply` is one: `admit`
/// runs synchronously on a libxpc event thread, and the test reads the result from another.
final class AdmissionOrderSpy: ConnectionAdmission, @unchecked Sendable {

    /// What one `admit` call saw. All three `false` is the correct answer.
    struct Observation: Sendable, Hashable {
        let hadExportedObject: Bool
        let hadExportedInterface: Bool
        let hadInvalidationHandler: Bool
    }

    private let lock = NSLock()
    private var recorded: [Observation] = []

    func admit(_ connection: NSXPCConnection) -> AdmissionDecision {
        let observation = Observation(
            hadExportedObject: connection.exportedObject != nil,
            hadExportedInterface: connection.exportedInterface != nil,
            hadInvalidationHandler: connection.invalidationHandler != nil
        )
        lock.lock()
        recorded.append(observation)
        lock.unlock()
        return .admitted(teamIdentifier: "TESTONLY")
    }

    var observations: [Observation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A real `NSXPCListener` and a real client connection to it, in this process.
///
/// The gate, the seam, the reply-block invariant, and the invalidation handler are all
/// exercised over an actual XPC round trip rather than by calling the actor directly.
/// Anonymous listeners need no mach service registration, no privilege, and no signing
/// identity, so this runs unchanged on CI.
///
/// The once-only reply latch it waits on is `AeolusXPCClient`'s `PendingReply`, not a copy
/// of it. This file used to own that type; promoting it into the client — which needs the
/// same latch for the same reason, and ships — left one implementation exercised by one
/// suite instead of two implementations of which only the test's was ever run.
/// `PendingReplyTests` is where it is tested directly.
///
/// ## The reply deadline is on a clock only the test moves
///
/// A message waits for its reply for ``replyDeadline``, counted on ``clock``, which nothing
/// moves but the test and ``ClockBackstop``
/// ([#583](https://github.com/blamechris/Aeolus/issues/583)). It was 10 s of `ContinuousClock`,
/// and a runner stall longer than that ran it out for a helper that had done nothing wrong:
/// `AnonymousListenerTests`, `OrderingExemptionTests` and `SupervisedApplyBoundaryTests` failed
/// together on the same "neither replied nor reported" text on 2026-10-29, twice, and a re-run of
/// the failed job passed both times.
///
/// **What it costs.** A reply that never comes ends the wait when the backstop runs the deadline
/// out, once the harness has lived 30 s of scheduled waiting time, and not at 10 s. The refuse-all
/// tests, whose claim is that a refused connection *fails* rather than hangs, are red on that
/// claim either way (`isPromptTransportFailure`, `timedOut`), 20 s later, and inside their
/// one-minute limit. A test whose claim is that the wait *has* a deadline moves ``clock`` itself.
///
/// Not `Sendable`, and not meant to be: one test owns one harness for its duration.
final class AnonymousListenerHarness {

    let listener: NSXPCListener
    let connection: NSXPCConnection

    /// How long a message waits for its reply, as the clock counts it: what a client is held to,
    /// and the figure a test moves ``clock`` by to run it out.
    static let replyDeadline: Duration = .seconds(10)

    /// What every reply wait here counts ``replyDeadline`` on. Frozen: see the type.
    let clock: ManualClock
    private let backstop: ClockBackstop

    /// `NSXPCListener` holds its delegate weakly. Held here for the harness's lifetime;
    /// without this the delegate would deallocate immediately and every connection would
    /// arrive with nothing to configure it.
    private let delegate: HelperListenerDelegate

    /// - Parameters:
    ///   - authority: what the helper's exported object answers through.
    ///   - admission: the code-signing decision, `UnenforcedAdmission` unless a test names one.
    ///   - backstopAfter: scheduled waiting time before ``ClockBackstop`` runs the reply deadline
    ///     out. Only a test of the backstop names one.
    init(
        authority: any FanAuthority,
        admission: any ConnectionAdmission = UnenforcedAdmission(),
        backstopAfter: Duration = .seconds(30)
    ) {
        let clock = ManualClock()
        self.clock = clock
        backstop = ClockBackstop(running: clock, after: backstopAfter)
        delegate = HelperListenerDelegate(
            admission: admission,
            authority: authority,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Listener")
        )

        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AeolusXPCProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
        listener.invalidate()
    }

    /// The proxy, with an error handler that answers the pending reply rather than
    /// dropping it.
    ///
    /// `remoteObjectProxyWithErrorHandler(_:)` and never bare `remoteObjectProxy`: when
    /// the connection itself fails, the block passed with the message is simply dropped
    /// and only this handler runs. A test that waited on the reply block alone would hang
    /// in exactly the case worth testing.
    private func proxy(
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws -> any AeolusXPCProtocol {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            onFailure(error)
        }
        guard let typed = proxy as? any AeolusXPCProtocol else {
            struct ProxyTypeMismatch: Error {}
            throw ProxyTypeMismatch()
        }
        return typed
    }

    /// Sends a payload-shaped message and waits for whichever of the reply block and the
    /// error handler runs — or gives up.
    func payloadMessage(
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Data?, Error?) -> Void) -> Void
    ) async -> Result<Data?, Error> {
        let pending = PendingReply<Result<Data?, Error>>(
            ifNothingArrives: .failure(NoReplyArrived()))
        do {
            let proxy = try proxy { pending.deliver(.failure($0)) }
            send(proxy) { data, error in
                pending.deliver(error.map { .failure($0) } ?? .success(data))
            }
        } catch {
            pending.deliver(.failure(error))
        }
        return await answer(of: pending)
    }

    /// The first answer to `reply`, or its fallback once ``replyDeadline`` has run out on
    /// ``clock``. The one place a wait on a reply is made, so none of them can reach for the wall
    /// clock again.
    func answer<Answer>(of reply: PendingReply<Answer>) async -> Answer {
        await reply.answer(within: Self.replyDeadline, on: clock)
    }

    /// Sends two payload-shaped messages back to back on one connection **without awaiting
    /// the first reply**, and answers with both results.
    ///
    /// This is the shape `AeolusXPCProtocol` now promises is legal — pipelining `hello` and
    /// `snapshot` to save a round trip at launch — and it cannot be expressed with two
    /// `payloadMessage` calls, because the first of those does not return until its reply
    /// has arrived. Both sends happen synchronously, one after the other, on this thread,
    /// so what reaches libxpc is the order this function's arguments are in and not an
    /// order the cooperative pool chose.
    func pipelinedPayloadMessages(
        _ first: (any AeolusXPCProtocol, @escaping @Sendable (Data?, Error?) -> Void) -> Void,
        _ second: (any AeolusXPCProtocol, @escaping @Sendable (Data?, Error?) -> Void) -> Void
    ) async -> (first: Result<Data?, Error>, second: Result<Data?, Error>) {
        let firstReply = PendingReply<Result<Data?, Error>>(
            ifNothingArrives: .failure(NoReplyArrived()))
        let secondReply = PendingReply<Result<Data?, Error>>(
            ifNothingArrives: .failure(NoReplyArrived()))
        do {
            let proxy = try proxy { error in
                firstReply.deliver(.failure(error))
                secondReply.deliver(.failure(error))
            }
            first(proxy) { data, error in
                firstReply.deliver(error.map { .failure($0) } ?? .success(data))
            }
            second(proxy) { data, error in
                secondReply.deliver(error.map { .failure($0) } ?? .success(data))
            }
        } catch {
            firstReply.deliver(.failure(error))
            secondReply.deliver(.failure(error))
        }
        return (await answer(of: firstReply), await answer(of: secondReply))
    }

    /// Sends two acknowledgement-shaped messages back to back on one connection **without
    /// awaiting the first reply**, and hands back both latches unawaited, so a test can look at
    /// what has been answered while the first message is still being handled.
    ///
    /// `pipelinedPayloadMessages`' shape for the verbs that answer with an error alone, `apply`
    /// among them. Each reply block appends its message's label to `replies` as it runs, `first`
    /// or `second`, so which had been answered by a given instant is a value a test can read
    /// without awaiting either.
    func pipelinedAcknowledgements(
        _ first: (any AeolusXPCProtocol, @escaping @Sendable (Error?) -> Void) -> Void,
        _ second: (any AeolusXPCProtocol, @escaping @Sendable (Error?) -> Void) -> Void,
        recordingInto replies: OrderRecord<String>
    ) -> (first: AwaitedReply<Error?>, second: AwaitedReply<Error?>) {
        let firstReply = PendingReply<Error?>(ifNothingArrives: NoReplyArrived())
        let secondReply = PendingReply<Error?>(ifNothingArrives: NoReplyArrived())
        do {
            let proxy = try proxy { error in
                firstReply.deliver(error)
                secondReply.deliver(error)
            }
            first(proxy) { error in
                replies.append("first")
                firstReply.deliver(error)
            }
            second(proxy) { error in
                replies.append("second")
                secondReply.deliver(error)
            }
        } catch {
            firstReply.deliver(error)
            secondReply.deliver(error)
        }
        return (AwaitedReply(firstReply, on: self), AwaitedReply(secondReply, on: self))
    }

    /// Sends an acknowledgement-shaped message and waits for the answer. `nil` means the
    /// helper said it succeeded.
    func acknowledgementMessage(
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Error?) -> Void) -> Void
    ) async -> Error? {
        let pending = PendingReply<Error?>(ifNothingArrives: NoReplyArrived())
        do {
            let proxy = try proxy { pending.deliver($0) }
            send(proxy) { error in pending.deliver(error) }
        } catch {
            pending.deliver(error)
        }
        return await answer(of: pending)
    }
}

/// A reply a test holds unawaited, which is awaited on the harness's clock when the test asks.
///
/// What `pipelinedAcknowledgements` hands back in place of the bare latch, whose own `answer()`
/// would count its deadline on the wall clock. Holds the clock, not the harness: a reply may be
/// read after the test is done with everything else.
struct AwaitedReply<Answer>: Sendable {

    private let latch: PendingReply<Answer>
    private let clock: ManualClock

    fileprivate init(_ latch: PendingReply<Answer>, on harness: AnonymousListenerHarness) {
        self.latch = latch
        self.clock = harness.clock
    }

    /// The first answer, or the fallback once ``AnonymousListenerHarness/replyDeadline`` has run
    /// out on the harness's clock.
    func answer() async -> Answer {
        await latch.answer(within: AnonymousListenerHarness.replyDeadline, on: clock)
    }
}

/// What a test gets when neither the reply block nor the error handler ever ran.
///
/// `AeolusXPCProtocol` says a reply block may never be invoked at all, and this is that
/// case made into a value. A test that simply waited would hang, which is the one outcome
/// a safety suite must not have — mutation testing produced exactly that: deleting the
/// delegate's refusal made the listener accept a connection it never configured, and the
/// suite stopped rather than failing.
struct NoReplyArrived: Error, CustomStringConvertible {
    var description: String {
        "the helper neither replied nor reported a transport failure within the deadline"
    }
}

extension Result where Success == Data?, Failure == Error {
    /// The Aeolus fault this result carries, or `nil` if it is not a refusal from this
    /// boundary.
    ///
    /// `AeolusXPCFault(nsError:)` returning `nil` is itself meaningful: it says "this did
    /// not come from Aeolus's boundary" — a transport failure rather than a refusal, which
    /// is the difference between the helper saying no and the helper never answering.
    var fault: AeolusXPCFault? {
        guard case .failure(let error) = self else { return nil }
        return AeolusXPCFault(nsError: error as NSError)
    }

    var payload: Data? {
        guard case .success(let data) = self else { return nil }
        return data
    }

    /// A failure that came from the transport **and arrived**, as distinct from this
    /// harness giving up.
    ///
    /// The distinction is load-bearing and mutation testing is what found that out.
    /// `isTransportFailure` alone was satisfied by `NoReplyArrived`, so the refuse-all
    /// tests passed whether the listener refused the connection promptly or simply never
    /// answered — which meant deleting the delegate's `return false` was a surviving
    /// mutation. A test that accepts "nothing happened" as evidence of refusal is not
    /// testing the refusal.
    var isPromptTransportFailure: Bool {
        guard case .failure(let error) = self, !(error is NoReplyArrived) else { return false }
        return AeolusXPCFault(nsError: error as NSError) == nil
    }

    var timedOut: Bool {
        guard case .failure(let error) = self else { return false }
        return error is NoReplyArrived
    }
}

extension Optional where Wrapped == Error {
    /// The Aeolus fault an acknowledgement-shaped reply carried, if any.
    var fault: AeolusXPCFault? {
        guard let self else { return nil }
        return AeolusXPCFault(nsError: self as NSError)
    }

    /// See `Result.isPromptTransportFailure`.
    var isPromptTransportFailure: Bool {
        guard let self, !(self is NoReplyArrived) else { return false }
        return AeolusXPCFault(nsError: self as NSError) == nil
    }

    var timedOut: Bool { self is NoReplyArrived }
}
