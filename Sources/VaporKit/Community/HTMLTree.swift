import Foundation

/// A small forgiving HTML tree for scraping Steam's community pages. It is not a browser parser:
/// it only needs to survive Valve's markup (unclosed `li`, stray end tags, huge inline scripts).
public final class HTMLNode {
    public let name: String                  // lowercase tag name, "#text", or "#root"
    public var attrs: [String: String] = [:]
    public var children: [HTMLNode] = []
    public var text = ""                     // decoded, for "#text" nodes
    public weak var parent: HTMLNode?

    init(name: String) { self.name = name }

    public var isText: Bool { name == "#text" }

    public func attr(_ key: String) -> String? { attrs[key] }

    public func hasClass(_ cls: String) -> Bool {
        guard let c = attrs["class"] else { return false }
        return c.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).contains { $0 == cls }
    }

    /// Depth-first search, the node itself excluded.
    public func first(where match: (HTMLNode) -> Bool) -> HTMLNode? {
        for child in children where !child.isText {
            if match(child) { return child }
            if let hit = child.first(where: match) { return hit }
        }
        return nil
    }

    public func all(where match: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        func walk(_ n: HTMLNode) {
            for child in n.children where !child.isText {
                if match(child) { out.append(child) }
                walk(child)
            }
        }
        walk(self)
        return out
    }

    public func first(class cls: String) -> HTMLNode? { first { $0.hasClass(cls) } }
    public func first(tag: String) -> HTMLNode? { first { $0.name == tag } }
    public func all(class cls: String) -> [HTMLNode] { all { $0.hasClass(cls) } }
    public func all(tag: String) -> [HTMLNode] { all { $0.name == tag } }
    public func first(id: String) -> HTMLNode? { first { $0.attrs["id"] == id } }

    /// Visible text with whitespace collapsed; `br` becomes a space.
    public var plainText: String {
        var out = ""
        func walk(_ n: HTMLNode) {
            if n.isText { out += n.text; return }
            if n.name == "script" || n.name == "style" { return }
            if n.name == "br" { out += " " }
            for c in n.children { walk(c) }
        }
        walk(self)
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum HTML {
    private static let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let rawText: Set<String> = ["script", "style", "textarea"]

    public static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(name: "#root")
        var stack = [root]
        let bytes = Array(html.utf8)
        let n = bytes.count
        var i = 0
        var textStart = 0

        func isNameByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x3A || b == 0x5F
        }
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }
        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            let s = decode(String(decoding: bytes[textStart..<end], as: UTF8.self))
            let node = HTMLNode(name: "#text")
            node.text = s
            node.parent = stack.last
            stack.last?.children.append(node)
        }
        func matches(_ at: Int, _ word: String) -> Bool {
            let w = Array(word.utf8)
            guard at + w.count <= n else { return false }
            for k in 0..<w.count where bytes[at + k] | 0x20 != w[k] | 0x20 { return false }
            return true
        }
        func find(_ word: String, from: Int) -> Int? {
            var k = from
            let w = Array(word.utf8)
            while k + w.count <= n {
                if bytes[k] == w[0], matches(k, word) { return k }
                k += 1
            }
            return nil
        }
        func close(_ name: String) {
            guard let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 else { return }
            stack.removeSubrange(idx...)
        }

        while i < n {
            guard bytes[i] == 0x3C else { i += 1; continue }                // '<'
            guard i + 1 < n else { break }
            let c = bytes[i + 1]
            if c == 0x21 {                                                   // <! comment / doctype
                flushText(upTo: i)
                if matches(i, "<!--") { i = (find("-->", from: i + 4) ?? n - 3) + 3 } else { i = (bytes[i...].firstIndex(of: 0x3E) ?? n - 1) + 1 }
                textStart = i; continue
            }
            if c == 0x2F {                                                   // end tag
                var j = i + 2
                let s = j
                while j < n, isNameByte(bytes[j]) { j += 1 }
                guard j > s else { i += 1; continue }
                flushText(upTo: i)
                close(String(decoding: bytes[s..<j], as: UTF8.self).lowercased())
                i = (bytes[j...].firstIndex(of: 0x3E) ?? n - 1) + 1
                textStart = i; continue
            }
            guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) else { i += 1; continue }
            flushText(upTo: i)
            var j = i + 1
            while j < n, isNameByte(bytes[j]) { j += 1 }
            let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self).lowercased()
            let node = HTMLNode(name: name)
            var selfClosed = false
            while j < n {                                                    // attributes
                while j < n, isSpace(bytes[j]) { j += 1 }
                guard j < n else { break }
                if bytes[j] == 0x3E { j += 1; break }
                if bytes[j] == 0x2F { selfClosed = true; j += 1; continue }
                let ks = j
                while j < n, !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                if j == ks { j += 1; continue }
                let key = String(decoding: bytes[ks..<j], as: UTF8.self).lowercased()
                while j < n, isSpace(bytes[j]) { j += 1 }
                var value = ""
                if j < n, bytes[j] == 0x3D {
                    j += 1
                    while j < n, isSpace(bytes[j]) { j += 1 }
                    if j < n, bytes[j] == 0x22 || bytes[j] == 0x27 {
                        let q = bytes[j]; j += 1
                        let vs = j
                        while j < n, bytes[j] != q { j += 1 }
                        value = String(decoding: bytes[vs..<min(j, n)], as: UTF8.self)
                        j += 1
                    } else {
                        let vs = j
                        while j < n, !isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                        value = String(decoding: bytes[vs..<j], as: UTF8.self)
                    }
                }
                if node.attrs[key] == nil { node.attrs[key] = decode(value) }
            }
            i = j
            textStart = i
            if name == "li" || name == "option", let top = stack.lastIndex(where: { $0.name == name || $0.name == "ul" || $0.name == "ol" || $0.name == "select" }),
               stack[top].name == name { stack.removeSubrange(top...) }
            node.parent = stack.last
            stack.last?.children.append(node)
            if voids.contains(name) || selfClosed { continue }
            if rawText.contains(name) {
                let end = find("</" + name, from: i) ?? n
                i = end; textStart = i
                continue
            }
            stack.append(node)
        }
        flushText(upTo: n)
        return root
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "bull": "•", "middot": "·", "times": "×",
    ]

    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            guard ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") else { out.append(ch); i = s.index(after: i); continue }
            let body = s[s.index(after: i)..<semi]
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let code = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                replacement = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[String(body)]
            }
            if let r = replacement { out += r; i = s.index(after: semi) } else { out.append(ch); i = s.index(after: i) }
        }
        return out
    }
}
