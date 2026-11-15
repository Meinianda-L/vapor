import Foundation

public enum VDFError: Error, Equatable {
    case unexpectedEnd
    case unexpectedToken(String, offset: Int)
    case badBinary(String)
}

/// Text KeyValues (`.vdf`, `.acf`) reader and writer.
public enum TextVDF {
    public static func parse(_ text: String) throws -> KeyValues {
        var lexer = Lexer(Array(text.utf8))
        var root: [(key: String, value: KeyValues)] = []
        while let token = try lexer.next() {
            guard case let .text(key) = token else { throw VDFError.unexpectedToken("\(token)", offset: lexer.pos) }
            root.append((key, try parseValue(&lexer)))
        }
        return .object(root)
    }

    public static func parse(contentsOf url: URL) throws -> KeyValues {
        try parse(String(decoding: Data(contentsOf: url), as: UTF8.self))
    }

    private static func parseValue(_ lexer: inout Lexer) throws -> KeyValues {
        guard let token = try lexer.next() else { throw VDFError.unexpectedEnd }
        switch token {
        case let .text(s): return .string(s)
        case .open:
            var children: [(key: String, value: KeyValues)] = []
            while true {
                guard let t = try lexer.next() else { throw VDFError.unexpectedEnd }
                switch t {
                case .close: return .object(children)
                case let .text(key): children.append((key, try parseValue(&lexer)))
                case .open: throw VDFError.unexpectedToken("{", offset: lexer.pos)
                }
            }
        case .close: throw VDFError.unexpectedToken("}", offset: lexer.pos)
        }
    }

    /// Serialises in Steam's own layout (tabs, `"key"\t\t"value"`).
    public static func serialize(_ kv: KeyValues) -> String {
        var out = ""
        for (key, value) in kv.children { write(key, value, depth: 0, into: &out) }
        return out
    }

    private static func write(_ key: String, _ value: KeyValues, depth: Int, into out: inout String) {
        let indent = String(repeating: "\t", count: depth)
        if case let .object(children) = value {
            out += "\(indent)\"\(escape(key))\"\n\(indent){\n"
            for (k, v) in children { write(k, v, depth: depth + 1, into: &out) }
            out += "\(indent)}\n"
        } else {
            out += "\(indent)\"\(escape(key))\"\t\t\"\(escape(value.string ?? ""))\"\n"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private enum Token { case text(String), open, close }

    private struct Lexer {
        let bytes: [UInt8]
        var pos = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() throws -> Token? {
            skipTrivia()
            guard pos < bytes.count else { return nil }
            switch bytes[pos] {
            case UInt8(ascii: "{"): pos += 1; return .open
            case UInt8(ascii: "}"): pos += 1; return .close
            case UInt8(ascii: "\""): return .text(try quoted())
            default: return .text(bare())
            }
        }

        private mutating func skipTrivia() {
            while pos < bytes.count {
                let c = bytes[pos]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xEF || c == 0xBB || c == 0xBF {
                    pos += 1                                   // whitespace and UTF-8 BOM
                } else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "/") {
                    while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
                } else if c == UInt8(ascii: "[") {             // platform conditional, e.g. [$WIN32]
                    while pos < bytes.count, bytes[pos] != UInt8(ascii: "]") { pos += 1 }
                    pos += 1
                } else {
                    return
                }
            }
        }

        private mutating func quoted() throws -> String {
            pos += 1
            var out: [UInt8] = []
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "\"") { pos += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\"), pos + 1 < bytes.count {
                    let n = bytes[pos + 1]
                    switch n {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "\\"), UInt8(ascii: "\""): out.append(n)
                    default: out.append(c); out.append(n)    // keep unknown escapes (Windows paths)
                    }
                    pos += 2
                    continue
                }
                out.append(c)
                pos += 1
            }
            throw VDFError.unexpectedEnd
        }

        private mutating func bare() -> String {
            let start = pos
            while pos < bytes.count {
                let c = bytes[pos]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == UInt8(ascii: "{") || c == UInt8(ascii: "}") || c == UInt8(ascii: "\"") { break }
                pos += 1
            }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }
    }
}
