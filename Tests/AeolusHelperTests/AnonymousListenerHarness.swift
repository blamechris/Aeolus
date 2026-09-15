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
/// Not `Sendable`, and not meant to be: one test owns one harness for its duration.
final class AnonymousListenerHarness {

    let listener: NSXPCListener
    let connection: NSXPCConnection

    /// `NSXPCListener` holds its delegate weakly. Held here for the harness's lifetime;
    /// without this the delegate would deallocate immediately and every connection would
    /// arrive with nothing to configure it.
    private let delegate: HelperListenerDelegate

    init(
        authority: any FanAuthority,
        admission: any ConnectionAdmission = UnenforcedAdmission()
    ) {
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
        return await pending.awaitingAnswer { resolve in
            do {
                let proxy = try proxy { resolve(.failure($0)) }
                send(proxy) { data, error in
                    resolve(error.map { .failure($0) } ?? .success(data))
                }
            } catch {
                resolve(.failure(error))
            }
        }
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
        return (await firstReply.answer(), await secondReply.answer())
    }

    /// Sends an acknowledgement-shaped message and waits for the answer. `nil` means the
    /// helper said it succeeded.
    func acknowledgementMessage(
        _ send: (any AeolusXPCProtocol, @escaping @Sendable (Error?) -> Void) -> Void
    ) async -> Error? {
        let pending = PendingReply<Error?>(ifNothingArrives: NoReplyArrived())
        return await pending.awaitingAnswer { resolve in
            do {
                let proxy = try proxy { resolve($0) }
                send(proxy) { error in resolve(error) }
            } catch {
                resolve(error)
            }
        }
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
