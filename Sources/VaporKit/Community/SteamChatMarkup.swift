import Foundation

/// Steam chat messages as rich text. Chat stores BBCode ([emoticon], [sticker], [spoiler], [quote], [code],
/// [url], [random], [flip], [mention], invites …) and keeps slash commands as typed (/me, /code, /pre,
/// /spoiler, /quote), which the client styles when it shows the message.
public enum SteamChatMarkup {
    public struct Message: Equatable, Sendable {
        public var blocks: [RichBlock]
        /// "/me …": shown as an action, after the sender's name.
        public var isAction = false
        /// Nothing but emoticons, which Steam draws large.
        public var onlyEmoticons = false
    }

    public static func parse(_ text: String) -> Message {
        let (command, rest) = slashCommand(text)
        switch command {
        case "/me": return Message(blocks: blocks(rest), isAction: true)
        case "/code", "/pre": return Message(blocks: [.code(rest)])
        case "/spoiler": return Message(blocks: [.paragraph([RichSpan(rest, spoiler: true)])])
        case "/quote": return Message(blocks: [.quote(author: nil, blocks(rest))])
        default:
            let out = blocks(text)
            let spans = out.flatMap { if case let .paragraph(s) = $0 { return s } else { return [RichSpan("x")] } }
            let only = !spans.isEmpty && spans.contains { $0.emoticon != nil }
                && spans.allSatisfy { $0.emoticon != nil || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return Message(blocks: out, onlyEmoticons: only)
        }
    }

    /// The command Steam recognises (first word, before any whitespace) and the text after it.
    static func slashCommand(_ text: String) -> (String?, String) {
        guard text.hasPrefix("/") else { return (nil, text) }
        let word = text.prefix { !$0.isWhitespace }
        guard ["/me", "/code", "/pre", "/spoiler", "/quote"].contains(word.lowercased()) else { return (nil, text) }
        return (word.lowercased(), String(text.dropFirst(word.count).drop { $0 == " " }))
    }

    public static func blocks(_ text: String) -> [RichBlock] {
        var builder = Builder()
        builder.walk(tokens(text))
        builder.flush()
        return builder.blocks
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case text(String)
        case open(name: String, arg: String?, attrs: [String: String])
        case close(String)
    }

    static func tokens(_ source: String) -> [Token] {
        var out: [Token] = []
        var text = ""
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            if c == "\\", source.index(after: i) < source.endIndex, source[source.index(after: i)] == "[" {
                text.append("[")
                i = source.index(i, offsetBy: 2)
                continue
            }
            if c == "[", let close = source[i...].firstIndex(of: "]"), let tag = tag(String(source[source.index(after: i)..<close])) {
                if !text.isEmpty { out.append(.text(text)); text = "" }
                out.append(tag)
                i = source.index(after: close)
                continue
            }
            text.append(c)
            i = source.index(after: i)
        }
        if !text.isEmpty { out.append(.text(text)) }
        return out
    }

    /// `[name]`, `[name=arg]`, `[name key=value key="value"]` or `[/name]`; anything else is text.
    static func tag(_ body: String) -> Token? {
        if body.hasPrefix("/") {
            let name = body.dropFirst().lowercased()
            return name.allSatisfy({ $0.isLetter || $0.isNumber }) && !name.isEmpty ? .close(name) : nil
        }
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard !name.isEmpty else { return nil }
        var rest = body.dropFirst(name.count)
        var arg: String?
        if rest.first == "=" {
            let value = rest.dropFirst()
            if value.first == "\"", let end = value.dropFirst().firstIndex(of: "\"") {
                arg = String(value[value.index(after: value.startIndex)..<end]); rest = value[value.index(after: end)...]
            } else {
                let end = value.firstIndex(of: " ") ?? value.endIndex
                arg = String(value[..<end]); rest = value[end...]
            }
        } else if let first = rest.first, first != " " {
            return nil
        }
        var attrs: [String: String] = [:]
        let source = String(rest), ns = source as NSString
        for m in attrPattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let value = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
            attrs[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: value)
        }
        return .open(name: name, arg: arg, attrs: attrs)
    }

    private static let attrPattern = try! NSRegularExpression(pattern: #"([A-Za-z_]+)=(?:"([^"]*)"|(\S+))"#)

    // MARK: - Building

    struct Style { var bold = false, italic = false, underline = false, strike = false, spoiler = false; var link: URL? }

    struct Builder {
        var blocks: [RichBlock] = []
        var runs: [RichSpan] = []

        mutating func text(_ s: String, _ st: Style) {
            guard !s.isEmpty else { return }
            // Bare web addresses in chat are links, as the client shows them.
            var rest = Substring(s)
            while let r = rest.range(of: #"https?://[^\s\[\]<>"]+"#, options: .regularExpression) {
                span(String(rest[..<r.lowerBound]), st)
                var linked = st
                linked.link = st.link ?? URL(string: String(rest[r]))
                span(String(rest[r]), linked)
                rest = rest[r.upperBound...]
            }
            span(String(rest), st)
        }

        mutating func span(_ s: String, _ st: Style) {
            guard !s.isEmpty else { return }
            let new = RichSpan(s, bold: st.bold, italic: st.italic, underline: st.underline, strike: st.strike, link: st.link, spoiler: st.spoiler)
            if let i = runs.indices.last, runs[i].sameStyle(as: new) { runs[i].text += s } else { runs.append(new) }
        }

        mutating func flush() {
            while let l = runs.last, l.emoticon == nil, l.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runs.removeLast() }
            if !runs.isEmpty { blocks.append(.paragraph(runs)) }
            runs = []
        }

        /// The tokens up to the matching close tag; a tag that is never closed has no body.
        static func inner(_ tokens: [Token], from i: inout Int, until name: String) -> [Token] {
            let start = i
            var depth = 0, out: [Token] = []
            while i < tokens.count {
                let t = tokens[i]; i += 1
                if case .open(name, _, _) = t { depth += 1 }
                if case .close(name) = t { if depth == 0 { return out }; depth -= 1 }
                out.append(t)
            }
            i = start
            return []
        }

        static func plain(_ tokens: [Token]) -> String {
            tokens.map { if case let .text(s) = $0 { return s } else { return "" } }.joined()
        }

        mutating func walk(_ tokens: [Token], _ style: Style = Style()) {
            var i = 0
            while i < tokens.count {
                let t = tokens[i]; i += 1
                switch t {
                case let .text(s):
                    text(s, style)
                case .close:
                    continue
                case let .open(name, arg, attrs):
                    let body = Self.inner(tokens, from: &i, until: name)
                    var st = style
                    switch name {
                    case "b": st.bold = true; walk(body, st)
                    case "i": st.italic = true; walk(body, st)
                    case "u": st.underline = true; walk(body, st)
                    case "s", "strike": st.strike = true; walk(body, st)
                    case "spoiler": st.spoiler = true; walk(body, st)
                    case "emoticon":
                        let n = Self.plain(body).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                        if !n.isEmpty { runs.append(.emoticon(n)) }
                    case "url":
                        st.link = URL(string: (arg ?? attrs["url"] ?? Self.plain(body)).trimmingCharacters(in: .whitespaces))
                            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                        if body.isEmpty { text(arg ?? "", st) } else { walk(body, st) }
                    case "mention":
                        st.bold = true; walk(body, st)
                    case "code", "pre":
                        flush(); blocks.append(.code(Self.plain(body)))
                    case "quote":
                        flush()
                        var nested = Builder(); nested.walk(body); nested.flush()
                        blocks.append(.quote(author: attrs["author"] ?? arg?.split(separator: ";").first.map(String.init), nested.blocks))
                    case "sticker":
                        if let type = attrs["type"] ?? arg { flush(); blocks.append(.sticker(type)) }
                    case "img":
                        if let u = URL(string: attrs["src"] ?? arg ?? Self.plain(body)), u.scheme?.hasPrefix("http") == true { flush(); blocks.append(.image(u)) }
                    case "random":
                        let lo = attrs["min"] ?? "1", hi = attrs["max"] ?? "", result = attrs["result"] ?? "?"
                        text(String(localized: "掷出随机数（\(lo)–\(hi)）："), style)
                        st.bold = true; text(result, st)
                    case "flip":
                        let heads = attrs["result"]?.lowercased() == "heads"
                        text(String(localized: "抛硬币："), style)
                        st.bold = true; text(heads ? String(localized: "正面") : String(localized: "反面"), st)
                    case "plusone":
                        text("+1", style)
                    case "gameinvite", "lobbyinvite":
                        text(String(localized: "［游戏邀请］"), style)
                    case "tradeoffer":
                        text(String(localized: "［交易报价］"), style)
                    case "broadcastinvite", "voicechannelinvite", "invite":
                        text(String(localized: "［邀请］"), style)
                    case "giphy", "og", "video", "youtube", "tweet":
                        let target = attrs["url"] ?? arg ?? Self.plain(body)
                        st.link = URL(string: target); text(target, st)
                    default:
                        walk(body, style)   // unknown tags keep their content
                    }
                }
            }
        }
    }
}
