import Foundation

public struct RichSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var code = false
    public var link: URL?
    /// Hidden until the reader reveals it.
    public var spoiler = false
    /// A Steam emoticon drawn as its image; `text` is its ":name:" fallback.
    public var emoticon: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false, code: Bool = false,
                link: URL? = nil, spoiler: Bool = false, emoticon: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike; self.code = code; self.link = link
        self.spoiler = spoiler; self.emoticon = emoticon
    }

    public static func emoticon(_ name: String) -> RichSpan { RichSpan(":\(name):", emoticon: name) }

    func sameStyle(as o: RichSpan) -> Bool {
        emoticon == nil && o.emoticon == nil && bold == o.bold && italic == o.italic && underline == o.underline && strike == o.strike
            && code == o.code && link == o.link && spoiler == o.spoiler
    }
}

public indirect enum RichBlock: Equatable, Sendable {
    case paragraph([RichSpan])
    case heading(String, level: Int)
    case image(URL)
    case quote(author: String?, [RichBlock])
    case list([[RichSpan]], ordered: Bool)
    case code(String)
    case video(URL)
    case rule
    /// A Steam chat sticker, by its type name.
    case sticker(String)

    /// Plain text of the block, for excerpts and tests.
    public var plain: String {
        switch self {
        case .paragraph(let s): return s.map(\.text).joined()
        case .heading(let t, _): return t
        case .quote(_, let b): return b.map(\.plain).joined(separator: "\n")
        case .list(let items, _): return items.map { $0.map(\.text).joined() }.joined(separator: "\n")
        case .code(let t): return t
        default: return ""
        }
    }
}

/// Steam's rendered post / guide / item HTML as a block list the UI can draw natively.
public enum RichText {
    public static func blocks(html: String, base: URL? = nil) -> [RichBlock] {
        blocks(node: HTML.parse(html), base: base)
    }

    public static func blocks(node: HTMLNode, base: URL? = nil) -> [RichBlock] {
        var b = Builder(base: base)
        b.walkChildren(node, Style())
        b.flush()
        return b.blocks
    }

    /// Resolves relative and `//` URLs and unwraps Steam's link filter.
    public static func resolve(_ raw: String, base: URL? = nil) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.lowercased().hasPrefix("javascript:") else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        var url = URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
        if let u = url, u.host == nil || u.scheme == nil, let base { url = URL(string: s, relativeTo: base)?.absoluteURL }
        if let u = url, u.path.hasPrefix("/linkfilter"), let target = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value,
           let inner = URL(string: target) { url = inner }
        guard let out = url, out.scheme == "http" || out.scheme == "https" else { return nil }
        return out
    }

    fileprivate struct Style {
        var bold = false, italic = false, underline = false, strike = false, code = false, spoiler = false
        var link: URL?
    }

    fileprivate struct Builder {
        let base: URL?
        var blocks: [RichBlock] = []
        var runs: [RichSpan] = []
        var pre = false

        init(base: URL?) { self.base = base }

        mutating func add(_ raw: String, _ style: Style) {
            var s = raw
            if !pre {
                s = s.replacingOccurrences(of: "[ \\t\\r\\n\\f]+", with: " ", options: .regularExpression)
                if s.hasPrefix(" "), let last = runs.last?.text, last.isEmpty || last.hasSuffix(" ") || last.hasSuffix("\n") { s.removeFirst() }
                else if s.hasPrefix(" "), runs.isEmpty { s.removeFirst() }
            }
            guard !s.isEmpty else { return }
            var span = RichSpan(s, bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, code: style.code,
                                link: style.link, spoiler: style.spoiler)
            if let i = runs.indices.last, runs[i].sameStyle(as: span) { runs[i].text += span.text } else { span.text = s; runs.append(span) }
        }

        mutating func flush() {
            while let f = runs.first, f.text.allSatisfy({ $0 == " " || $0 == "\n" }) { runs.removeFirst() }
            while let l = runs.last, l.text.allSatisfy({ $0 == " " || $0 == "\n" }) { runs.removeLast() }
            guard !runs.isEmpty else { return }
            if let f = runs.first { runs[0].text = String(f.text.drop { $0 == " " || $0 == "\n" }) }
            if let l = runs.indices.last { runs[l].text = String(runs[l].text.reversed().drop { $0 == " " || $0 == "\n" }.reversed()) }
            for i in runs.indices {
                runs[i].text = runs[i].text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                    .replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
            }
            blocks.append(.paragraph(runs.filter { !$0.text.isEmpty }))
            runs = []
        }

        mutating func walkChildren(_ n: HTMLNode, _ style: Style) {
            for c in n.children { walk(c, style) }
        }

        mutating func walk(_ n: HTMLNode, _ style: Style) {
            if n.isText { add(n.text, style); return }
            var st = style
            switch n.name {
            case "script", "style", "head", "select", "form", "button", "input": return
            case "br": runs.append(RichSpan("\n", bold: style.bold, italic: style.italic, link: style.link)); return
            case "hr": flush(); blocks.append(.rule); return
            case "b", "strong": st.bold = true
            case "i", "em": st.italic = true
            case "u": st.underline = true
            case "s", "strike", "del": st.strike = true
            case "span":
                if n.hasClass("bb_strike") { st.strike = true }
                if n.hasClass("bb_underline") { st.underline = true }
                if n.hasClass("bb_spoiler") { st.spoiler = true }
            case "a":
                if let href = n.attr("href"), let url = RichText.resolve(href, base: base) { st.link = url }
            case "img":
                image(n)
                return
            case "iframe":
                if let src = n.attr("src"), let url = Self.video(src) { flush(); blocks.append(.video(url)) }
                return
            case "h1", "h2", "h3", "h4", "h5", "h6":
                heading(n, level: Int(n.name.dropFirst()) ?? 3); return
            case "pre":
                flush()
                let t = n.plainTextPreserved
                if !t.isEmpty { blocks.append(.code(t)) }
                return
            case "blockquote":
                quote(n); return
            case "ul", "ol":
                list(n, ordered: n.name == "ol"); return
            case "code":
                st.code = true
            case "div", "p", "section", "article", "center", "table", "tr", "tbody", "thead", "dl", "dt", "dd", "figure", "li":
                if n.hasClass("bb_h1") || n.hasClass("bb_h2") || n.hasClass("bb_h3") {
                    heading(n, level: n.hasClass("bb_h1") ? 1 : n.hasClass("bb_h2") ? 2 : 3); return
                }
                if n.hasClass("bb_code") {
                    flush()
                    let t = n.plainTextPreserved
                    if !t.isEmpty { blocks.append(.code(t)) }
                    return
                }
                if n.hasClass("bb_quoteauthor") { return }
                flush()
                walkChildren(n, st)
                flush()
                return
            case "td", "th":
                walkChildren(n, st)
                add("   ", st)
                return
            default: break
            }
            walkChildren(n, st)
        }

        mutating func heading(_ n: HTMLNode, level: Int) {
            flush()
            let t = n.plainText
            if !t.isEmpty { blocks.append(.heading(t, level: min(level, 3))) }
        }

        mutating func image(_ n: HTMLNode) {
            guard let src = n.attr("src") else { return }
            if src.contains("/economy/emoticon/") {
                let name = (n.attr("alt") ?? n.attr("title") ?? String(src.split(separator: "/").last ?? ""))
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if !name.isEmpty { runs.append(.emoticon(name)) }
                return
            }
            guard let url = RichText.resolve(src, base: base) else { return }
            flush()
            blocks.append(.image(url))
        }

        mutating func quote(_ n: HTMLNode) {
            flush()
            var author: String?
            if let a = n.first(class: "bb_quoteauthor") {
                let t = a.plainText.trimmingCharacters(in: CharacterSet(charactersIn: ":： ")).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { author = t }
            }
            var inner = Builder(base: base)
            inner.walkChildren(n, Style())
            inner.flush()
            blocks.append(.quote(author: author, inner.blocks))
        }

        mutating func list(_ n: HTMLNode, ordered: Bool) {
            flush()
            var items: [[RichSpan]] = []
            for li in n.children where li.name == "li" {
                var inner = Builder(base: base)
                inner.walkChildren(li, Style())
                inner.flush()
                let spans = inner.blocks.compactMap { b -> [RichSpan]? in if case .paragraph(let s) = b { return s }; return nil }
                    .reduce(into: [RichSpan]()) { acc, s in if !acc.isEmpty { acc.append(RichSpan("\n")) }; acc += s }
                if !spans.isEmpty { items.append(spans) }
            }
            if !items.isEmpty { blocks.append(.list(items, ordered: ordered)) }
        }

        static func video(_ src: String) -> URL? {
            guard let u = RichText.resolve(src) else { return nil }
            if u.host?.contains("youtube") == true, let id = u.pathComponents.last, id != "embed" {
                return URL(string: "https://www.youtube.com/watch?v=\(id)")
            }
            return u
        }
    }
}

extension HTMLNode {
    /// Text with its original whitespace and line breaks (for code blocks).
    var plainTextPreserved: String {
        var out = ""
        func walk(_ n: HTMLNode) {
            if n.isText { out += n.text; return }
            if n.name == "br" { out += "\n"; return }
            for c in n.children { walk(c) }
        }
        walk(self)
        return out.trimmingCharacters(in: .newlines)
    }
}
