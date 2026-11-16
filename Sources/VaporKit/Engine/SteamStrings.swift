import Foundation

/// Steam's own UI strings, read from steamui's localization bundles so Vapor says exactly what Steam
/// says ("地区受限", "即将进行" …). The bundles are webpack chunks wrapping `JSON.parse('…')`.
public struct SteamStrings: Sendable {
    private let table: [String: String]

    public init(table: [String: String]) { self.table = table }

    /// Loads `shared_` and `steamui_<language>-json.js` (falling back to English) from a Steam install. The
    /// shared bundle holds the plain buttons (Button_OK, Button_Cancel …); steamui wins where both have a key.
    public init(steamRoot: URL, language: String = "schinese") {
        let dir = steamRoot.appendingPathComponent("steamui/localization")
        var table: [String: String] = [:]
        for lang in ["english", language] where lang == "english" || language != "english" {
            for bundle in ["shared", "steamui"] {
                guard let text = try? String(contentsOf: dir.appendingPathComponent("\(bundle)_\(lang)-json.js"), encoding: .utf8) else { continue }
                table.merge(Self.parse(bundle: text)) { $1 }
            }
        }
        self.table = table
    }

    public var isEmpty: Bool { table.isEmpty }

    /// `key` without the leading '#'; `%1$s`-style arguments are substituted in order.
    public func callAsFunction(_ key: String, _ args: String...) -> String? { text(key, args) }

    public func text(_ key: String, _ args: [String]) -> String? {
        guard var s = table[key] else { return nil }
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$s", with: a) }
        return s
    }

    /// Steam's text for an EAppUpdateError (the install wizard's eAppError).
    public func appUpdateError(_ code: Int) -> String? { self("Steam_AppUpdateError_\(code)") }

    static func parse(bundle text: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(text)
        while let start = rest.range(of: "JSON.parse('") {
            guard let literal = jsSingleQuoted(rest[start.upperBound...]) else { break }
            if let data = literal.value.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj { if let s = v as? String { result[k] = s } }
            }
            rest = rest[literal.end...]
        }
        return result
    }

    /// Unescapes a JS single-quoted string body starting right after the opening quote.
    static func jsSingleQuoted(_ s: Substring) -> (value: String, end: Substring.Index)? {
        var out = String.UnicodeScalarView()
        var i = s.unicodeScalars.startIndex
        let scalars = s.unicodeScalars
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "'" { return (String(out), i) }
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
