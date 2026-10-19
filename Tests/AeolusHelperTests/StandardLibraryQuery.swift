/// Questions about a type, asked by the standard library's own names, in a file that imports
/// nothing (#456's review, B2).
///
/// In a file that imports SMCCore, a name SMCCore declares shadows the standard library's. A
/// top-level `typealias Decodable = Swift.Decodable & Swift.Hashable` in SMCCore turns
/// `is any Decodable.Type` there into a question about `Decodable & Hashable`, which a `Decodable`
/// type that is not `Hashable` answers no (P3). An internal `enum Swift` does the same to
/// `Swift.Decodable` (P4), and `WritableKeyPath` can be shadowed the same way. Here no SMCCore
/// name is in scope, so each name below is the standard library's. `SMCRequestConstructionTests`
/// holds this file to importing nothing.
enum StandardLibraryQuery {

    static func isDecodable(_ type: Any.Type) -> Bool { type is any Decodable.Type }

    static func isEncodable(_ type: Any.Type) -> Bool { type is any Encodable.Type }

    static func isCodable(_ type: Any.Type) -> Bool { type is any Codable.Type }

    /// Whether `keyPath` is writable at run time, whatever its static type. A key path to a
    /// property with a setter the caller cannot reach is a `KeyPath` to the compiler and a
    /// `WritableKeyPath` to a cast (SR-5218).
    static func isWritable<Root, Value>(_ keyPath: KeyPath<Root, Value>) -> Bool {
        keyPath is WritableKeyPath<Root, Value>
    }
}

/// A `private(set)` property declared in another file than the key path to it, the shape
/// SR-5218 makes writable by a cast: the premise for `StandardLibraryQuery.isWritable`.
struct PrivateSetterTwin {
    private(set) var selector: UInt8 = 0
}
