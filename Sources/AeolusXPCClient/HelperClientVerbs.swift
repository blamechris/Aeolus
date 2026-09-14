import AeolusXPC
import FanKit
import Foundation

/// The seven messages, as functions a caller can hold onto.
///
/// Split from the actor's own file, and along a real seam rather than a line count:
/// everything here is a **verb**, and no verb touches this client's state. Each one encodes
/// what it is sending, goes through one of the two gates, and decodes what came back. That
/// is the whole of a verb, and it is why the interesting parts of this target — the
/// handshake, the connection's lifecycle, and what a transport failure means — are not in
/// this file.
///
/// The DTOs cross **unchanged**, `capturedAt` and `expiresAt` included. Nothing here
/// reshapes a helper's answer into a client's convenience type, and nothing keeps a copy of
/// one: a stale snapshot is not forbidden here, it is unrepresentable.
extension HelperClient {

    /// Everything the helper can currently say about the machine.
    ///
    /// A fresh round trip every time. There is deliberately nothing to return when the
    /// round trip fails.
    public func snapshot() async throws -> SystemSnapshot {
        let data: Data = try await withHandshakenProxy { proxy, resolve in
            proxy.snapshot { data, error in resolve(HelperClientPayload.outcome(data, error)) }
        }
        return try HelperClientPayload.decode(SystemSnapshot.self, from: data)
    }

    /// Asks for manual control of the requested fans.
    ///
    /// The `Lease` that comes back is returned unchanged, `expiresAt` included — which is
    /// display-grade and enforced by nobody, as `Lease` itself says. Renewal is the
    /// caller's job, on `Lease.defaultHeartbeatInterval`; this client renews nothing on its
    /// own, because a lease renewed by the transport layer is a lease nobody is proving
    /// they still want.
    public func acquireLease(_ request: LeaseRequest) async throws -> Lease {
        let payload = try HelperClientPayload.encode(request)
        let data: Data = try await withHandshakenProxy { proxy, resolve in
            proxy.acquireLease(request: payload) { data, error in
                resolve(HelperClientPayload.outcome(data, error))
            }
        }
        return try HelperClientPayload.decode(Lease.self, from: data)
    }

    /// Extends a lease this connection acquired.
    ///
    /// A lease is bound to the connection that acquired it, so a renewal after a reconnect
    /// is refused with `AeolusXPCFault.leaseNotHeldByThisConnection` — correctly. That
    /// refusal is the client's signal to acquire again if it still wants the fans, and it is
    /// not something this type papers over.
    public func renewLease(id: UUID) async throws -> Lease {
        let data: Data = try await withHandshakenProxy { proxy, resolve in
            proxy.renewLease(id: id.uuidString) { data, error in
                resolve(HelperClientPayload.outcome(data, error))
            }
        }
        return try HelperClientPayload.decode(Lease.self, from: data)
    }

    /// Gives a lease back and returns its fans to automatic.
    public func releaseLease(id: UUID) async throws {
        try await withHandshakenProxy { proxy, resolve in
            proxy.releaseLease(id: id.uuidString) { error in
                resolve(HelperClientPayload.acknowledgement(error))
            }
        }
    }

    /// Applies fan settings under a lease.
    ///
    /// Success means the helper accepted and applied the request, not that a fan reached a
    /// speed: what the firmware does with a clamped target is reported by the next
    /// `snapshot()`, never inferred from this returning.
    public func apply(_ settings: [FanSetting], leaseID: UUID) async throws {
        let payload = try HelperClientPayload.encode(settings)
        try await withHandshakenProxy { proxy, resolve in
            proxy.apply(settings: payload, leaseID: leaseID.uuidString) { error in
                resolve(HelperClientPayload.acknowledgement(error))
            }
        }
    }

    /// The panic path: every fan back to automatic, every lease dropped.
    ///
    /// **The one message that does not wait for a handshake**, because the helper exempts it
    /// from the gate — its only expressible effect is the safe state, and a version fence
    /// that stopped a panicked user's older client from restoring automatic control would be
    /// a safety mechanism defeating safety. It still travels on a connection libxpc admitted
    /// against the code-signing requirement.
    ///
    /// Returning means **the helper accepted the request**. It does not mean a fan is
    /// spinning at an automatic speed: the restore's completion is the control plane's to
    /// give, and on the wedged `io_connect_t` of `docs/SAFETY.md` § 4 it may never come. A
    /// caller reporting this to a user says the helper accepted the reset, never that the
    /// fans were restored.
    public func restoreAllToAutomatic() async throws {
        try await withProxy { proxy, resolve in
            proxy.restoreAllToAutomatic { error in
                resolve(HelperClientPayload.acknowledgement(error))
            }
        }
    }
}
