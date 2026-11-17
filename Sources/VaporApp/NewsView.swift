import SwiftUI
import AppKit

// MARK: - Data

struct NewsItem: Identifiable, Sendable {
    let id: String
    let title: String
    let url: URL?
    let author: String
    let feedLabel: String
    let date: Date
    /// BBCode, whatever the feed delivered (HTML feeds are converted on arrival).
    let markup: String
    let excerpt: String
    let cover: URL?

    var meta: String {
        let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "zh_CN")))
        return feedLabel.isEmpty ? day : "\(day) · \(feedLabel)"
    }
}

/// GetNewsForApp takes no language parameter (l=schinese returns the same items), so the text is shown as published.
@MainActor
enum NewsFeed {
    private static var cache: [UInt32: (fetched: Date, items: [NewsItem])] = [:]
    private static let lifetime: TimeInterval = 600

    static func cached(_ appid: UInt32) -> [NewsItem]? {
        guard let hit = cache[appid], Date().timeIntervalSince(hit.fetched) < lifetime else { return nil }
        return hit.items
    }

    static func items(_ appid: UInt32, force: Bool = false) async throws -> [NewsItem] {
        if !force, let hit = cached(appid) { return hit }
        let items = try await download(appid)
        cache[appid] = (Date(), items)
        return items
    }

    private struct Reply: Decodable {
        struct Raw: Decodable {
            let gid: String?, title: String?, url: String?, author: String?, contents: String?
            let feedlabel: String?, feedname: String?, date: Int?
        }
        struct AppNews: Decodable { let newsitems: [Raw] }
        let appnews: AppNews
    }

    nonisolated private static func download(_ appid: UInt32) async throws -> [NewsItem] {
        guard let url = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appid)&count=20&maxlength=0&format=json") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return reply.appnews.newsitems.enumerated().map { index, raw in
            let announcement = raw.feedname == "steam_community_announcements"
            let contents = raw.contents ?? ""
            let looksHTML = !announcement && contents.range(of: "<(p|br|div|h[1-6]|li|img|a)[ >/]", options: [.regularExpression, .caseInsensitive]) != nil
            let markup = looksHTML ? EulaText.bbcode(fromHTML: NewsMarkup.imagesToBBCode(contents)) : contents
            let label = announcement ? String(localized: "官方公告") : (raw.feedlabel ?? "")
            return NewsItem(
                id: raw.gid ?? raw.url ?? "\(index)", title: raw.title ?? "", url: raw.url.flatMap(URL.init(string:)),
                author: raw.author ?? "", feedLabel: label, date: Date(timeIntervalSince1970: TimeInterval(raw.date ?? 0)),
                markup: markup, excerpt: NewsMarkup.excerpt(markup), cover: NewsMarkup.firstImage(markup))
        }
    }
}

// MARK: - BBCode

enum NewsBlock: Sendable {
    case heading(String, Int)
    case text(AttributedString)
    case list([AttributedString], ordered: Bool)
    case image(URL)
    case video(URL)
    case rule
}

enum NewsMarkup {
    static func resolve(_ raw: String, upgrade: Bool = false) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let base = "https://clan.akamai.steamstatic.com/images/"
        for placeholder in ["{STEAM_CLAN_IMAGE}", "{STEAM_CLAN_LOC_IMAGE}"] {
            s = s.replacingOccurrences(of: placeholder + "/", with: base).replacingOccurrences(of: placeholder, with: base)
        }
        if s.hasPrefix("//") { s = "https:" + s }
        if upgrade, s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        return URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    static func imagesToBBCode(_ html: String) -> String {
        html.replacingOccurrences(of: "<img[^>]*?src\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>", with: "\n[img]$1[/img]\n",
                                  options: [.regularExpression, .caseInsensitive])
    }

    static func firstImage(_ markup: String) -> URL? {
        guard let r = markup.range(of: "\\[img[^\\]]*\\][\\s\\S]*?\\[/img\\]", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(markup[r])
        guard let open = tag.firstIndex(of: "]"), let close = tag.range(of: "[/img]", options: [.caseInsensitive, .backwards]) else { return nil }
        return resolve(String(tag[tag.index(after: open)..<close.lowerBound]), upgrade: true)
    }

    static func excerpt(_ markup: String) -> String {
        var s = markup.replacingOccurrences(of: "\\[img[^\\]]*\\][\\s\\S]*?\\[/img\\]", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\[/?[A-Za-z0-9*]+(?:[ =][^\\]\\n]*)?\\]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\([\\[\\]])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{STEAM_[A-Z_]+\\}\\S*", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String(s.prefix(140))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\\]]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        return tag[r].drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Steam announcement BBCode: headings, paragraphs, lists, links, images and video previews.
    /// Pure Swift, so it can run off the main thread.
    static func parse(_ source: String) -> [NewsBlock] {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [NewsBlock] = []
        var cur = AttributedString()
        var trailing = 0                        // newlines at the end of `cur`, capped at two
        var items: [AttributedString]?
        var ordered = false
        var bold = 0, italic = 0, underline = 0, strike = 0, heading = 0
        var link: URL?

        func emit(_ s: String, link override: URL? = nil) {
            var kept = ""
            for ch in s {
                if ch == "\n" { if trailing >= 2 { continue }; trailing += 1 } else { trailing = 0 }
                kept.append(ch)
            }
            guard !kept.isEmpty else { return }
            var a = AttributedString(kept)
            let size: CGFloat = heading == 1 ? 20 : heading == 2 ? 17 : heading == 3 ? 15 : 14
            var font = Font.system(size: size, weight: bold > 0 || heading > 0 ? .semibold : .regular)
            if italic > 0 { font = font.italic() }
            a.font = font
            if underline > 0 { a.underlineStyle = .single }
            if strike > 0 { a.strikethroughStyle = .single }
            if let url = override ?? link { a.link = url; a.foregroundColor = Theme.accent }
            cur += a
        }
        func trimmed(_ a: AttributedString) -> AttributedString {
            var a = a
            while let f = a.characters.first, f.isWhitespace { a.characters.removeFirst() }
            while let l = a.characters.last, l.isWhitespace { a.characters.removeLast() }
            return a
        }
        func flushText() {
            let t = trimmed(cur)
            if !t.characters.isEmpty { blocks.append(.text(t)) }
            cur = AttributedString(); trailing = 0
        }
        func flushItem() {
            let t = trimmed(cur)
            if !t.characters.isEmpty { items?.append(t) }
            cur = AttributedString(); trailing = 0
        }
        func endHeading() {
            let s = String(cur.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { blocks.append(.heading(s, heading)) }
            cur = AttributedString(); trailing = 0; heading = 0
        }
        func endList() {
            flushItem()
            if let it = items, !it.isEmpty { blocks.append(.list(it, ordered: ordered)) }
            items = nil
        }
        func raw(from: String.Index, until closing: String) -> (String, String.Index) {
            guard let r = text.range(of: closing, options: .caseInsensitive, range: from..<text.endIndex) else {
                return (String(text[from...]), text.endIndex)
            }
            return (String(text[from..<r.lowerBound]), r.upperBound)
        }

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "[", let close = text[i...].firstIndex(of: "]"), text.distance(from: i, to: close) < 400 {
                let inner = String(text[text.index(after: i)..<close])
                let name = String(inner.lowercased().prefix { $0 != "=" && $0 != " " })
                let after = text.index(after: close)
                let value = inner.firstIndex(of: "=").map { String(inner[inner.index(after: $0)...]) } ?? ""
                var next = after
                var known = true
                switch name {
                case "b": bold += 1
                case "/b": bold = max(0, bold - 1)
                case "i": italic += 1
                case "/i": italic = max(0, italic - 1)
                case "u": underline += 1
                case "/u": underline = max(0, underline - 1)
                case "strike", "s": strike += 1
                case "/strike", "/s": strike = max(0, strike - 1)
                case "h1", "h2", "h3", "h4":
                    flushText(); heading = Int(name.dropFirst()).map { min($0, 3) } ?? 3
                case "/h1", "/h2", "/h3", "/h4": if heading > 0 { endHeading() }
                case "p", "/p": flushText()
                case "br": emit("\n")
                case "hr": flushText(); blocks.append(.rule)
                case "list", "olist":
                    flushText()
                    if items == nil { items = []; ordered = name == "olist" }
                case "*": if items != nil { flushItem() } else { emit("\n•  ") }
                case "/list", "/olist": endList()
                case "/*": break
                case "/tr": emit("\n")
                case "/td", "/th": emit("   ")
                case "url":
                    if value.isEmpty {
                        let (content, end) = raw(from: after, until: "[/url]")
                        let target = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        emit(target, link: resolve(target))
                        next = end
                    } else {
                        link = resolve(value)
                    }
                case "/url": link = nil
                case "img":
                    let (content, end) = raw(from: after, until: "[/img]")
                    next = end
                    if let url = resolve(attribute("src", in: inner) ?? content, upgrade: true), items == nil {
                        flushText(); blocks.append(.image(url))
                    }
                case "previewyoutube":
                    let id = value.prefix { $0 != ";" }
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(id)"), !id.isEmpty { flushText(); blocks.append(.video(url)) }
                case "video":
                    if let url = (attribute("mp4", in: inner) ?? attribute("webm", in: inner) ?? attribute("src", in: inner)).flatMap({ resolve($0) }) {
                        flushText(); blocks.append(.video(url))
                    }
                case "noparse", "code":
                    let (content, end) = raw(from: after, until: "[/\(name)]")
                    emit(content); next = end
                case "quote", "/quote", "table", "/table", "tr", "td", "th", "spoiler", "/spoiler", "/previewyoutube", "/video", "/code", "/noparse":
                    break
                default: known = false
                }
                if known { i = next; continue }
            }
            if text[i] == "\\", text.index(after: i) < text.endIndex, "[]".contains(text[text.index(after: i)]) {
                emit(String(text[text.index(after: i)]))      // Steam escapes literal brackets as \[ and \]
                i = text.index(i, offsetBy: 2)
                continue
            }
            let end = text[text.index(after: i)...].firstIndex { $0 == "[" || $0 == "\\" } ?? text.endIndex
            emit(String(text[i..<end]))
            i = end
        }
        if items != nil { endList() }
        if heading > 0 { endHeading() }
        flushText()
        return blocks
    }
}

// MARK: - Images

@MainActor
private enum NewsImages {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

private struct NewsImage: View {
    let url: URL
    /// A fixed frame crops to fill (thumbnails); nil shows the picture at its own size, up to `maxWidth`.
    var fill: CGSize?
    var maxWidth: CGFloat = 680
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let fill {
                Rectangle().fill(Color(white: 0.12))
                    .frame(width: fill.width, height: fill.height)
                    .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, maxWidth), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if !failed {
                Rectangle().fill(Color(white: 0.12)).frame(maxWidth: maxWidth).frame(height: 140)
            }
        }
        .task(id: url) {
            image = await NewsImages.image(url)
            failed = image == nil
        }
    }
}

// MARK: - Views

private func webURL(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

/// The three newest items for a game's page.
struct NewsSection: View {
    let appid: UInt32
    var openAll: () -> Void
    @State private var items: [NewsItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty {
                HStack {
                    SectionLabel(text: String(localized: "新闻"))
                    Spacer()
                    Button("全部新闻", action: openAll)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(.bottom, 10)
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    Button(action: openAll) { row(item) }.buttonStyle(.plain)
                }
            }
        }
        .task(id: appid) {
            items = NewsFeed.cached(appid) ?? []
            if let fresh = try? await NewsFeed.items(appid) { items = fresh }
        }
    }

    private func row(_ item: NewsItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                Text(item.meta).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                if !item.excerpt.isEmpty {
                    Text(item.excerpt).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let cover = item.cover { NewsImage(url: cover, fill: CGSize(width: 112, height: 63)) }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A game's news: list on the left, the selected article rendered natively on the right.
struct NewsView: View {
    let appid: UInt32
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}

    private enum Phase { case loading, failed, loaded([NewsItem]) }
    @State private var phase = Phase.loading
    @State private var selected: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("新闻").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("关闭", action: onClose).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 40).padding(.top, 36).padding(.bottom, 18)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .environment(\.openURL, OpenURLAction { url in
            guard webURL(url) else { return .discarded }
            open(url)
            return .handled
        })
        .task(id: "\(appid)-\(attempt)") {
            if let hit = NewsFeed.cached(appid) { show(hit); return }
            phase = .loading
            do {
                show(try await NewsFeed.items(appid, force: attempt > 0))
            } catch {
                if !Task.isCancelled { phase = .failed }
            }
        }
    }

    private func show(_ items: [NewsItem]) {
        phase = .loaded(items)
        if selected == nil || !items.contains(where: { $0.id == selected }) { selected = items.first?.id }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            note(String(localized: "正在加载…"))
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text("暂时无法加载新闻。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Button("重试") { attempt += 1 }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
            }
            .padding(40)
        case .loaded(let items) where items.isEmpty:
            note(String(localized: "这款游戏暂无新闻。"))
        case .loaded(let items):
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in listRow(item) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                }
                .frame(width: 300)
                Divider().overlay(Theme.hairline)
                if let item = items.first(where: { $0.id == selected }) {
                    ArticleReader(item: item, open: open).id(item.id)
                } else {
                    Spacer()
                }
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(40)
    }

    private func listRow(_ item: NewsItem) -> some View {
        let on = item.id == selected
        return Button { selected = item.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Theme.accent : Theme.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(item.meta).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ArticleReader: View {
    let item: NewsItem
    let open: (URL) -> Void
    @State private var blocks: [NewsBlock]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(item.author.isEmpty ? item.meta : "\(item.author) · \(item.meta)")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        if let url = item.url, webURL(url) {
                            Button("原文") { open(url) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary).underline()
                        }
                    }
                }
                .padding(.bottom, 8)
                if let blocks {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in render(block) }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            let markup = item.markup
            blocks = await Task.detached(priority: .userInitiated) { NewsMarkup.parse(markup) }.value
        }
    }

    @ViewBuilder private func render(_ block: NewsBlock) -> some View {
        switch block {
        case .heading(let s, let level):
            Text(s).font(.system(size: level == 1 ? 18 : level == 2 ? 15.5 : 14, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.top, 8).textSelection(.enabled)
        case .text(let a):
            Text(a).foregroundStyle(Theme.text.opacity(0.88)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .list(let entries, let ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.offset) { n, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(n + 1)." : "•").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(entry).foregroundStyle(Theme.text.opacity(0.88)).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        case .image(let url):
            NewsImage(url: url)
        case .video(let url):
            HStack {
                Text(url.host?.contains("youtube") == true ? "YouTube 视频" : String(localized: "视频")).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                Button("在浏览器中观看") { open(url) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider().overlay(Theme.hairline)
        }
    }
}
