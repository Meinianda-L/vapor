import SwiftUI
import AppKit
import WebKit
import VaporKit

// Shared pieces of the native community pages: page chrome, loading, images, rich text.

enum CommunityTime {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        return f
    }()

    static func string(_ date: Date?) -> String {
        guard let date else { return "" }
        let age = Date().timeIntervalSince(date)
        if age < 30 * 86_400, age > -3600 { return relative.localizedString(for: date, relativeTo: Date()) }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "zh_CN")))
    }
}

/// The signed-in web session Vapor's store already keeps in sync with Windows Steam.
@MainActor
enum CommunitySession {
    static func cookieHeader() async -> String? {
        let cookies = await WKWebsiteDataStore(forIdentifier: SteamWebSession.dataStoreID).httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("steamcommunity.com") }
        guard cookies.contains(where: { $0.name == "steamLoginSecure" }) else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

func communityWeb(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

/// Author links only go native for profiles Vapor can draw; vanity URLs would end up on the web.
func communityProfile(_ url: URL?) -> URL? {
    guard let url, url.host?.hasSuffix("steamcommunity.com") == true, url.path.hasPrefix("/profiles/") else { return nil }
    return url
}

// MARK: - Chrome

struct CommunityFrame<Accessory: View, Content: View>: View {
    var title: String?
    var back = "返回"
    var open: (URL) -> Void
    var onBack: () -> Void
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: onBack) {
                    Text("‹ \(back)").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                if title != nil || Accessory.self != EmptyView.self {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        if let title { Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text) }
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                content
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .environment(\.openURL, OpenURLAction { url in
            guard communityWeb(url) else { return .discarded }
            open(url)
            return .handled
        })
    }
}

extension CommunityFrame where Accessory == EmptyView {
    init(title: String?, back: String = "返回", open: @escaping (URL) -> Void, onBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, back: back, open: open, onBack: onBack, accessory: { EmptyView() }, content: content)
    }
}

struct CommunityNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.vertical, 6)
    }
}

struct CommunitySkeleton: View {
    var rows = 6
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<rows, id: \.self) { i in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: i % 2 == 0 ? 360 : 280, height: 12)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 190, height: 9)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Loads a value for `id` (again whenever `id` changes), keeps the old content dimmed meanwhile and
/// cancels with the view. `load` runs off the main actor, so parsing there is free.
struct Loadable<Value: Sendable, Content: View>: View {
    let id: AnyHashable
    var rows = 6
    let load: @Sendable () async throws -> Value
    var onLoad: (Value) -> Void = { _ in }
    @ViewBuilder let content: (Value) -> Content

    private struct Key: Hashable { let id: AnyHashable; let attempt: Int }
    @State private var value: Value?
    @State private var failed = false
    @State private var busy = false
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if failed {
                HStack(spacing: 10) {
                    Text("没有加载出来。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Button("重试") { attempt += 1 }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                }
            }
            if let value {
                content(value).opacity(busy ? 0.4 : 1).allowsHitTesting(!busy)
            } else if !failed {
                CommunitySkeleton(rows: rows)
            }
        }
        .task(id: Key(id: id, attempt: attempt)) {
            busy = true
            failed = false
            do {
                let v = try await load()
                guard !Task.isCancelled else { return }
                value = v
                onLoad(v)
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            busy = false
        }
    }
}

struct TextTabs<Tag: Hashable>: View {
    let items: [(Tag, String)]
    @Binding var selection: Tag
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { selection = item.0 } label: {
                        Text(item.1).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selection == item.0 ? Theme.accent : Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CommunitySearchField: View {
    let prompt: String
    @Binding var text: String
    var submit: () -> Void
    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: 210)
            .onSubmit(submit)
    }
}

struct CommunityPager: View {
    let page: Int
    var pageCount: Int?
    var hasNext = true
    let go: (Int) -> Void
    var body: some View {
        let last = pageCount.map { page >= $0 } ?? !hasNext
        HStack(spacing: 20) {
            Button("‹ 上一页") { go(page - 1) }.disabled(page <= 1)
            Text(pageCount.map { "第 \(page) 页，共 \($0) 页" } ?? "第 \(page) 页")
                .foregroundStyle(Theme.secondary).monospacedDigit()
            Button("下一页 ›") { go(page + 1) }.disabled(last)
        }
        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text)
        .padding(.top, 6)
    }
}

// MARK: - Images

@MainActor
enum CommunityImages {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A cropped picture in a box of fixed shape (cards, thumbnails).
struct CommunityThumb: View {
    let url: URL?
    var aspect: CGFloat = 16.0 / 9
    var radius: CGFloat = 5
    @State private var image: NSImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .task(id: url) {
                guard let url else { image = nil; return }
                image = await CommunityImages.image(url)
            }
    }
}

/// A picture at its own proportions, up to `maxWidth`.
struct CommunityPicture: View {
    let url: URL
    var maxWidth: CGFloat = 680
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, maxWidth), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if !failed {
                Rectangle().fill(Color(white: 0.12)).frame(maxWidth: maxWidth).frame(height: 140)
            }
        }
        .task(id: url) {
            image = await CommunityImages.image(url)
            failed = image == nil
        }
    }
}

struct CommunityAvatar: View {
    let url: URL?
    var size: CGFloat = 32
    var body: some View {
        CommunityThumb(url: url, aspect: 1, radius: 4).frame(width: size, height: size)
    }
}

// MARK: - Rich text

struct RichBlocksView: View {
    let blocks: [RichBlock]
    var size: CGFloat = 14
    var maxImage: CGFloat = 680
    @Environment(\.openURL) private var openURL

    private enum Item { case block(RichBlock), images([URL]) }

    private var items: [Item] {
        var out: [Item] = []
        var run: [URL] = []
        func flush() { if !run.isEmpty { out.append(.images(run)); run = [] } }
        for b in blocks {
            if case .image(let u) = b { run.append(u) } else { flush(); out.append(.block(b)) }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .images(let urls) where urls.count == 1:
                    CommunityPicture(url: urls[0], maxWidth: maxImage)
                case .images(let urls):
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 230), spacing: 8, alignment: .topLeading)], alignment: .leading, spacing: 8) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { _, u in CommunityPicture(url: u, maxWidth: 230) }
                    }
                case .block(let b):
                    render(b)
                }
            }
        }
    }

    static func attributed(_ spans: [RichSpan], size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for s in spans {
            var a = AttributedString(s.text)
            var font = Font.system(size: s.code ? size - 1 : size, weight: s.bold ? .semibold : .regular, design: s.code ? .monospaced : .default)
            if s.italic { font = font.italic() }
            a.font = font
            if s.underline { a.underlineStyle = .single }
            if s.strike { a.strikethroughStyle = .single }
            if let link = s.link { a.link = link; a.foregroundColor = Theme.accent }
            out += a
        }
        return out
    }

    @ViewBuilder private func render(_ block: RichBlock) -> some View {
        switch block {
        case .paragraph(let spans):
            Text(Self.attributed(spans, size: size)).foregroundStyle(Theme.text.opacity(0.88)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .heading(let t, let level):
            Text(t).font(.system(size: level == 1 ? 18 : level == 2 ? 15.5 : 14, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.top, 8).textSelection(.enabled)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, spans in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(n + 1)." : "•").font(.system(size: size)).foregroundStyle(Theme.secondary).frame(width: 20, alignment: .trailing)
                        Text(Self.attributed(spans, size: size)).foregroundStyle(Theme.text.opacity(0.88)).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        case .quote(let author, let inner):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.hairline).frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    if let author { Text(author).font(.system(size: 11.5)).foregroundStyle(Theme.secondary) }
                    RichBlocksView(blocks: inner, size: max(12, size - 1), maxImage: maxImage - 20).opacity(0.85)
                }
            }
        case .code(let t):
            Text(t).font(.system(size: size - 1.5, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.88))
                .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .video(let url):
            HStack {
                Text(url.host?.contains("youtube") == true ? "YouTube 视频" : "视频").font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                Button("在浏览器中观看") { openURL(url) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider().overlay(Theme.hairline)
        case .image(let u):
            CommunityPicture(url: u, maxWidth: maxImage)
        }
    }
}

/// What a list opens in place.
enum CommunityDetail: Hashable {
    case thread(URL)
    case file(UInt64)
}
