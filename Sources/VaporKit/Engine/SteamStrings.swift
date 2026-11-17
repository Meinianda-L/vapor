import Foundation

/// Steam's own UI strings, read from steamui's localization bundles so Vapor says exactly what Steam
/// says ("地区受限", "即将进行" …). The bundles are webpack chunks wrapping `JSON.parse('…')` (the English ones a
/// template literal, `JSON.parse(`…`)`).
public struct SteamStrings: Sendable {
    private let table: [String: String]
    /// Steam's English text per token: what the client renders, so rendered text can be traced back to its token.
    private let english: [String: String]
    private let templates: TemplateIndex

    public init(table: [String: String], english: [String: String] = [:]) {
        self.table = table
        self.english = english
        templates = TemplateIndex(english: english)
    }

    /// Loads `shared_` and `steamui_<language>-json.js` (falling back to English) from a Steam install. The
    /// shared bundle holds the plain buttons (Button_OK, Button_Cancel …); steamui wins where both have a key.
    public init(steamRoot: URL, language: String = "schinese") {
        let dir = steamRoot.appendingPathComponent("steamui/localization")
        var table: [String: String] = [:]
        var english: [String: String] = [:]
        for lang in ["english", language] where lang == "english" || language != "english" {
            for bundle in ["shared", "steamui"] {
                guard let text = try? String(contentsOf: dir.appendingPathComponent("\(bundle)_\(lang)-json.js"), encoding: .utf8) else { continue }
                let strings = Self.parse(bundle: text)
                table.merge(strings) { $1 }
                if lang == "english" { english.merge(strings) { $1 } }
            }
        }
        self.init(table: table, english: english)
    }

    public var isEmpty: Bool { table.isEmpty }

    /// `key` without the leading '#'; `%1$s`-style arguments are substituted in order.
    public func callAsFunction(_ key: String, _ args: String...) -> String? { text(key, args) }

    public func text(_ key: String, _ args: [String]) -> String? {
        guard var s = table[key] else { return nil }
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$s", with: a) }
        return s
    }

    /// Steam's text for a rendered English string: the token whose English text is exactly `text`, or whose English
    /// template (`Download of %1$s failed`) fits it, with the arguments read out of `text`. Nil when no token fits
    /// or Steam has no translation for it.
    public func localize(_ text: String) -> String? {
        guard let (key, args) = match(text) else { return nil }
        return self.text(key, args)
    }

    public func match(_ text: String) -> (key: String, args: [String])? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let key = templates.exact[s] { return (key, []) }
        return templates.match(s)
    }

    /// Steam's text for an EAppUpdateError (the install wizard's eAppError).
    public func appUpdateError(_ code: Int) -> String? { self("Steam_AppUpdateError_\(code)") }

    static func parse(bundle text: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(text)
        while let start = rest.range(of: "JSON.parse(") {
            let body = rest[start.upperBound...]
            guard let quote = body.first, quote == "'" || quote == "`",
                  let literal = jsQuoted(body.dropFirst(), quote: Character(String(quote))) else {
                rest = rest[start.upperBound...]
                continue
            }
            if let data = literal.value.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj { if let s = v as? String { result[k] = s } }
            }
            rest = rest[literal.end...]
        }
        return result
    }

    /// Unescapes a JS quoted string body (single quote or template literal) starting right after the opening quote.
    static func jsQuoted(_ s: Substring, quote: Character = "'") -> (value: String, end: Substring.Index)? {
        let closing = Unicode.Scalar(String(quote)) ?? "'"
        var out = String.UnicodeScalarView()
        var i = s.unicodeScalars.startIndex
        let scalars = s.unicodeScalars
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == closing { return (String(out), i) }
            if c == "\\" {
                i = scalars.index(after: i)
                guard i < scalars.endIndex else { return nil }
                let e = scalars[i]
                switch e {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u", "x":
                    let count = e == "u" ? 4 : 2
                    var hex = ""
                    for _ in 0..<count {
                        i = scalars.index(after: i)
                        guard i < scalars.endIndex else { return nil }
                        hex.unicodeScalars.append(scalars[i])
                    }
                    guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { return nil }
                    out.append(u)
                default: out.append(e)       // \' \\ \" → the character itself
                }
            } else {
                out.append(c)
            }
            i = scalars.index(after: i)
        }
        return nil
    }
}

/// Steam's English tokens as patterns: a token's text with `%1$s` … placeholders matches the text the client rendered
/// with the placeholders filled in. Built once, on first use.
private final class TemplateIndex: @unchecked Sendable {
    let exact: [String: String]
    private let english: [String: String]
    private let lock = NSLock()
    private var compiled: [Template]?

    private struct Template {
        let key: String
        let regex: NSRegularExpression
        let order: [Int]          // capture group → placeholder number
        let literal: Int          // characters that are not placeholders: how specific the template is
    }

    init(english: [String: String]) {
        self.english = english
        // Several tokens share a text ("Close"); the plain button and dialog ones read best in Chinese too.
        func plain(_ k: String) -> Bool { k.hasPrefix("Button_") || k.hasPrefix("Generic_") || k.hasPrefix("Dialog_") }
        var exact: [String: String] = [:]
        for (k, v) in english where !v.contains("%") {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if let had = exact[t], !(plain(k) && !plain(had)) && !(plain(k) == plain(had) && k < had) { continue }
            exact[t] = k
        }
        self.exact = exact
    }

    func match(_ text: String) -> (key: String, args: [String])? {
        let templates = load()
        let range = NSRange(text.startIndex..., in: text)
        var best: (Template, [String])?
        for t in templates where t.literal > (best?.0.literal ?? 3) {
            guard let m = t.regex.firstMatch(in: text, range: range), m.range == range else { continue }
            var args = [String](repeating: "", count: (t.order.max() ?? 0))
            for (group, number) in t.order.enumerated() {
                if let r = Range(m.range(at: group + 1), in: text) { args[number - 1] = String(text[r]) }
            }
            best = (t, args)
        }
        return best.map { ($0.0.key, $0.1) }
    }

    private func load() -> [Template] {
        lock.lock(); defer { lock.unlock() }
        if let compiled { return compiled }
        let placeholder = try? NSRegularExpression(pattern: #"%(\d+)\$s"#)
        var list: [Template] = []
        for (key, value) in english where value.contains("$s") && !value.contains("<1>") {
            let ns = value as NSString
            let found = placeholder?.matches(in: value, range: NSRange(location: 0, length: ns.length)) ?? []
            guard !found.isEmpty else { continue }
            var pattern = "^", at = 0, order: [Int] = [], literal = 0
            for m in found {
                let chunk = ns.substring(with: NSRange(location: at, length: m.range.location - at))
                pattern += NSRegularExpression.escapedPattern(for: chunk) + "(.+?)"
                literal += chunk.count
                order.append(Int(ns.substring(with: m.range(at: 1))) ?? 0)
                at = m.range.location + m.range.length
            }
            let tail = ns.substring(from: at)
            pattern += NSRegularExpression.escapedPattern(for: tail) + "$"
            literal += tail.count
            guard order.allSatisfy({ $0 > 0 }),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            list.append(Template(key: key, regex: regex, order: order, literal: literal))
        }
        compiled = list
        return list
    }
}
