import AeolusXPC
import Foundation

/// The two reply shapes this boundary uses, and the coding either side of them.
///
/// A namespace rather than members of the actor, because none of it touches a connection or
/// any state: given the two values libxpc handed a reply block, these say what the contract
/// makes of them. Keeping them out here is what lets the actor's own file be about the
/// connection.
///
/// `AeolusXPCProtocol` states the invariant these enforce: **exactly one of the two is
/// non-nil.** `(nil, nil)` is a protocol violation rather than an empty success, and a
/// client that reads it as one has invented an answer the helper never gave.
enum HelperClientPayload {

    /// `(Data?, Error?)`, with the contract's own invariant applied.
    ///
    /// `(nil, nil)` is a protocol violation and never an empty success —
    /// `AeolusXPCProtocol` says so, and a client that read it as one would render an answer
    /// the helper never gave as the state of the machine.
    static func outcome(_ data: Data?, _ error: Error?) -> Result<Data, Error> {
        if let error { return .failure(error) }
        guard let data else {
            return .failure(
                HelperClientError.protocolViolation(
                    detail: "the helper's reply carried neither a payload nor a refusal"))
        }
        return .success(data)
    }

    /// `(Error?)`: `nil` means the helper carried the request out.
    static func acknowledgement(_ error: Error?) -> Result<Void, Error> {
        if let error { return .failure(error) }
        return .success(())
    }

    static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try AeolusXPCCoding.encoder().encode(value)
        } catch {
            throw HelperClientError.protocolViolation(
                detail:
                    "this client could not encode its own \(type(of: value)) request: \(error)")
        }
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data
    ) throws -> Value {
        do {
            return try AeolusXPCCoding.decoder().decode(type, from: data)
        } catch {
            throw HelperClientError.protocolViolation(
                detail: "the helper's \(type) did not decode: \(error)")
        }
    }
}
