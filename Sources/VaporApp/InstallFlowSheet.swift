import AppKit
import SwiftUI
import VaporKit

/// The install wizard's user steps, in Vapor: Steam's own dialog never opens (the agent detached it).
struct InstallFlowSheet: View {
    let run: SteamUI.Install
    /// Closes the sheet without asking Steam, for when Windows Steam is gone and cannot be told to cancel.
    var onClose: () -> Void = {}
    @EnvironmentObject var engine: EngineModel
    /// Rendered agreements by EULA id: rendering a long one takes a while and must not run on every update.
    @State private var rendered: [String: AttributedString] = [:]

    private var name: String { engine.steamApps[run.appid]?.name ?? "App \(run.appid)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "安装 \(name)")).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            switch run.step {
            case "eula": eula
            case "cdkey": cdkey
            default: other
            }
        }
        .padding(24)
        .frame(width: 620)
        .task(id: run.eulas?.map(\.id) ?? []) { await renderEulas() }
    }

    private var subtitle: String {
        switch run.step {
        case "eula": return String(localized: "继续安装前，需要同意以下协议。")
        case "cdkey": return String(localized: "这款游戏附带 CD Key，激活时可能会用到。")
        default: return String(localized: "需要额外步骤。")
        }
    }

    private func renderEulas() async {
        for e in run.eulas ?? [] where rendered[e.id] == nil {
            guard let content = e.content else { continue }
            rendered[e.id] = await Task.detached(priority: .userInitiated) { EulaText.render(content) }.value
        }
    }

    /// The step's buttons while Steam can act on them; otherwise a short notice and a way out.
    @ViewBuilder private func footer<B: View>(note: String = "", @ViewBuilder _ buttons: () -> B) -> some View {
        HStack(spacing: 10) {
            if engine.uiOnline {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                buttons()
            } else {
                Text(String(localized: "Windows Steam 已离线，安装无法继续。")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Button(engine.strings("Button_Close") ?? String(localized: "关闭"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private var eula: some View {
        if let eulas = run.eulas, !eulas.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(eulas) { e in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(e.title ?? String(localized: "最终用户许可协议")).font(.system(size: 14, weight: .semibold))
                            if e.content != nil {
                                if let text = rendered[e.id] {
                                    Text(text).font(.system(size: 12)).textSelection(.enabled)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            } else {
                                Link(String(localized: "在浏览器中阅读"), destination: URL(string: e.url.replacingOccurrences(of: "http://", with: "https://"))!)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 380)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            footer(note: eulas.count > 1 ? String(localized: "共 \(eulas.count) 份协议") : "") {
                Button(String(localized: "拒绝")) { engine.cancelInstall() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "同意并继续")) { engine.acceptEulas() }.keyboardShortcut(.defaultAction)
            }
        } else {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(String(localized: "正在读取协议…")).font(.system(size: 12)) }
            footer { Button(String(localized: "取消安装")) { engine.cancelInstall() }.keyboardShortcut(.cancelAction) }
        }
    }

    @ViewBuilder private var cdkey: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(run.keys ?? [], id: \.key) { k in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.name).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Text(k.key).font(.system(size: 14, weight: .medium).monospaced()).textSelection(.enabled)
                    }
                    Spacer()
                    Button(String(localized: "复制")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(k.key, forType: .string)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            }
        }
        footer {
            Button(String(localized: "取消安装")) { engine.cancelInstall() }.keyboardShortcut(.cancelAction)
            Button(String(localized: "继续")) { engine.continueInstall() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var other: some View {
        Text(run.step == "password" ? String(localized: "这个游戏需要预载解锁密码，Vapor 还不支持在这里输入。") : String(localized: "Steam 要求注册第三方账号后才能继续。"))
            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        footer { Button(String(localized: "取消安装")) { engine.cancelInstall() }.keyboardShortcut(.defaultAction) }
    }
}

/// Steam EULAs are BBCode (some older ones HTML). Renders the common tags; drops the rest.
/// Pure Swift, so it can run off the main thread.
enum EulaText {
    static func render(_ source: String) -> AttributedString {
        let isHTML = source.range(of: "<(p|br|div|h[1-6]|li)[ >/]", options: [.regularExpression, .caseInsensitive]) != nil
        return bbcode(isHTML ? bbcode(fromHTML: source) : source)
    }

    /// Rewrites the HTML tags a EULA uses as their BBCode equivalents, drops the others and decodes entities.
    static func bbcode(fromHTML source: String) -> String {
        var out = ""
        var space = false                       // HTML collapses runs of whitespace into one space
        var i = source.startIndex
        func put(_ s: String) {
            if space && !out.isEmpty && !out.hasSuffix("\n") && !s.hasPrefix("\n") { out += " " }
            space = false
            out += s
        }
        while i < source.endIndex {
            let c = source[i]
            if c == "<", let close = source[i...].firstIndex(of: ">") {
                let raw = source[source.index(after: i)..<close]
                let lower = raw.lowercased()
                let closing = lower.hasPrefix("/")
                let name = String(lower.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber })
                i = source.index(after: close)
                switch name {
                case "br": space = false; out += "\n"
                case "p", "div", "tr", "table", "ul", "ol", "blockquote": space = false; out += "\n\n"
                case "h1", "h2", "h3", "h4", "h5", "h6": space = false; out += closing ? "[/h1]" : "[h1]"
                case "li": if !closing { space = false; out += "[*]" }
                case "b", "strong": put(closing ? "[/b]" : "[b]")
                case "i", "em": put(closing ? "[/i]" : "[i]")
                case "u": put(closing ? "[/u]" : "[u]")
                case "a":
                    if closing { out += "[/url]" }
                    else if let href = attribute("href", in: String(raw)) { put("[url=\(href)]") }
                case "script", "style":
                    if !closing, let end = source.range(of: "</\(name)", options: .caseInsensitive, range: i..<source.endIndex) {
                        i = source[end.upperBound...].firstIndex(of: ">").map(source.index(after:)) ?? source.endIndex
                    }
                default: break
                }
                continue
            }
            if c.isWhitespace { space = true; i = source.index(after: i); continue }
            if c == "&", let semi = source[i...].prefix(10).firstIndex(of: ";"), let ch = entity(source[source.index(after: i)..<semi]) {
                put(ch)
                i = source.index(after: semi)
                continue
            }
            let next = source[i...].firstIndex { $0 == "<" || $0 == "&" || $0.isWhitespace } ?? source.endIndex
            put(String(source[i..<max(next, source.index(after: i))]))
            i = max(next, source.index(after: i))
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = tag[r].drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty || value.contains("]") ? nil : value
    }

    private static func entity(_ e: Substring) -> String? {
        switch e {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard e.hasPrefix("#") else { return nil }
            let digits = e.dropFirst()
            let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    static func bbcode(_ source: String) -> AttributedString {
        var out = AttributedString()
        var bold = 0, italic = 0, underline = 0, heading = 0
        var link: URL?
        var pendingLink: [String] = []          // [url]text[/url]: the text is the link
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        var i = text.startIndex
        func emit(_ s: String) {
            guard !s.isEmpty else { return }
            var a = AttributedString(s)
            var font = Font.system(size: heading > 0 ? 14 : 12, weight: bold > 0 || heading > 0 ? .semibold : .regular)
            if italic > 0 { font = font.italic() }
            a.font = font
            if underline > 0 { a.underlineStyle = .single }
            if let link { a.link = link; a.foregroundColor = Theme.accent }
            out += a
        }
        while i < text.endIndex {
            if text[i] == "[", let close = text[i...].firstIndex(of: "]") {
                let tag = text[text.index(after: i)..<close].lowercased()
                var handled = true
                switch tag {
                case "b": bold += 1
                case "/b": bold = max(0, bold - 1)
                case "i": italic += 1
                case "/i": italic = max(0, italic - 1)
                case "u": underline += 1
                case "/u": underline = max(0, underline - 1)
                case "h1", "h2", "h3": heading += 1; emit("\n")
                case "/h1", "/h2", "/h3": heading = max(0, heading - 1); emit("\n")
                case "list", "olist", "/list", "/olist": emit("\n")
                case "*": emit("\n•  ")
                case "hr", "hr/": emit("\n———\n")
                case "url": pendingLink.append(""); link = nil
                case "/url":
                    if let raw = pendingLink.popLast(), !raw.isEmpty {
                        var a = AttributedString(raw)
                        a.font = .system(size: 12)
                        a.foregroundColor = Theme.accent
                        a.link = URL(string: raw.hasPrefix("http") ? raw : "https://" + raw)
                        out += a
                    }
                    link = nil
                default:
                    if tag.hasPrefix("url=") {
                        let target = String(text[text.index(i, offsetBy: 5)..<close])
                        link = URL(string: target.hasPrefix("http") ? target : "https://" + target)
                    } else if tag.hasPrefix("/") || ["table", "tr", "td", "th", "quote", "code", "noparse", "spoiler", "strike", "/strike"].contains(tag) {
                        // Structural tags we do not style.
                    } else {
                        handled = false
                    }
                }
                if handled { i = text.index(after: close); continue }
            }
            // Plain run up to the next '['.
            let next = text[text.index(after: i)...].firstIndex(of: "[") ?? text.endIndex
            let chunk = String(text[i..<next])
            if !pendingLink.isEmpty { pendingLink[pendingLink.count - 1] += chunk } else { emit(chunk) }
            i = next
        }
        // An unterminated [url] must not swallow the rest of the agreement.
        for raw in pendingLink { emit(raw) }
        return out
    }
}
