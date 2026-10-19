/// Questions about a type, asked by the standard library's own names, in a file that imports
/// nothing (#456's review, B2).
///
/// In a file that imports SMCCore, a name SMCCore declares shadows the standard library's. A
/// top-level `typealias Decodable = Swift.Decodable & Swift.Hashable` in SMCCore turns
/// `is any Decodable.Type` there into a question about `Decodable & Hashable`, which a `Decodable`
/// type that is not `Hashable` answers no (P3). An internal `enum Swift` does the same to
/// `Swift.Decodable` (P4), and `WritableKeyPath` can be shadowed the same way. This file imports
/// nothing, so SMCCore's internal names are not in scope here, and `SMCRequestConstructionTests`
/// holds it to that.
///
/// **That is all it protects against.** Names visible to the whole test target are in scope here
/// too. A public SMCCore `typealias Decodable` re-exported by another test file's
/// `@_exported import SMCCore` (X1), or a `typealias Decodable` the test target declares (T2),
/// changes what `Decodable` means below, as an alias of any other name used here would change its
/// question. Neither is caught by the import pin. Under both, with `Decodable & Encodable` as the
/// alias, the check on `Request` passes and only `theRequestIsNotCodable`'s premise spelled
/// `Swift.Decodable` goes red; that premise is not a general guard against what the test target
/// can declare.
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
