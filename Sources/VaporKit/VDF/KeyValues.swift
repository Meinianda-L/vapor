import Foundation

/// A Valve KeyValues tree, shared by text VDF files and binary appinfo.
/// Children keep their original order so files round-trip unchanged.
public enum KeyValues: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case float(Double)
    case object([(key: String, value: KeyValues)])

    public static func == (lhs: KeyValues, rhs: KeyValues) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.float(a), .float(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    /// Case-insensitive child lookup, like Valve's own KeyValues.
    public subscript(key: String) -> KeyValues? {
        guard case let .object(children) = self else { return nil }
        return children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Walks a path of keys, e.g. `kv[path: "appinfo", "common", "name"]`.
    public subscript(path keys: String...) -> KeyValues? {
        keys.reduce(Optional(self)) { node, key in node?[key] }
    }

    public var children: [(key: String, value: KeyValues)] {
        if case let .object(c) = self { return c }
        return []
    }

    /// Scalar value as text; numbers are rendered the way Steam writes them.
    public var string: String? {
        switch self {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .float(f): return String(f)
        case .object: return nil
        }
    }

    public var int: Int64? {
        switch self {
        case let .int(i): return i
        case let .string(s): return Int64(s)
        case let .float(f): return Int64(f)
        case .object: return nil
        }
    }

    /// Sets (or adds) a child, creating intermediate objects along `path`.
    public mutating func set(_ value: KeyValues, at path: [String]) {
        guard let first = path.first else { self = value; return }
        var children = self.children
        if let i = children.firstIndex(where: { $0.key.caseInsensitiveCompare(first) == .orderedSame }) {
            var child = children[i].value
            if path.count > 1, case .object = child {} else if path.count > 1 { child = .object([]) }
            child.set(value, at: Array(path.dropFirst()))
            children[i].value = child
        } else {
            var child = KeyValues.object([])
            child.set(value, at: Array(path.dropFirst()))
            children.append((first, child))
        }
        self = .object(children)
    }
}
