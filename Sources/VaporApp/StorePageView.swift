import AVKit
import SwiftUI
import VaporKit

/// What the store page shows, decoded loosely from Steam's public appdetails and appreviews endpoints.
struct StorePage: Sendable {
    struct Price: Sendable { let final: String; let initial: String; let discount: Int }
    struct Movie: Sendable, Identifiable { let id: Int; let name: String; let thumbnail: URL?; let video: URL? }
    struct Shot: Sendable, Identifiable { let id: Int; let thumb: URL?; let full: URL? }
    struct Reviews: Sendable { let label: String; let positive: Int; let total: Int }
    struct DLC: Sendable, Identifiable { let id: Int; let name: String; let price: Price?; let free: Bool }

    var name = ""
    var shortDescription = ""
    var aboutHTML = ""
    var developers: [String] = []
    var publishers: [String] = []
    var releaseDate = ""
    var comingSoon = false
    var genres: [String] = []
    var categories: [String] = []
    var price: Price?
    var isFree = false
    var movies: [Movie] = []
    var shots: [Shot] = []
    var minimum = ""
    var recommended = ""
    var languages = ""
    var metacritic: Int?
    var dlc: [Int] = []

    private static func url(_ any: Any?) -> URL? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return URL(string: s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : s)
    }

    private static func price(_ any: Any?) -> Price? {
        guard let p = any as? [String: Any], let final = p["final_formatted"] as? String else { return nil }
        let initial = p["initial_formatted"] as? String ?? ""
        return Price(final: final, initial: initial, discount: p["discount_percent"] as? Int ?? 0)
    }

    static func parse(details data: Data, appid: UInt32) -> StorePage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root[String(appid)] as? [String: Any], entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any] else { return nil }
        var p = StorePage()
        p.name = d["name"] as? String ?? ""
        p.shortDescription = d["short_description"] as? String ?? ""
        p.aboutHTML = d["about_the_game"] as? String ?? ""
        p.developers = d["developers"] as? [String] ?? []
        p.publishers = (d["publishers"] as? [String] ?? []).filter { !$0.isEmpty }
        let release = d["release_date"] as? [String: Any]
        p.releaseDate = release?["date"] as? String ?? ""
        p.comingSoon = release?["coming_soon"] as? Bool ?? false
        p.genres = (d["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        p.categories = (d["categories"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        p.price = price(d["price_overview"])
        p.isFree = d["is_free"] as? Bool ?? false
        p.movies = (d["movies"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? Int else { return nil }
            let mp4 = m["mp4"] as? [String: Any]
            return Movie(id: id, name: m["name"] as? String ?? "", thumbnail: url(m["thumbnail"]), video: url(mp4?["max"]) ?? url(mp4?["480"]))
        }
        p.shots = (d["screenshots"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["id"] as? Int else { return nil }
            return Shot(id: id, thumb: url(s["path_thumbnail"]), full: url(s["path_full"]))
        }
        if let pc = d["pc_requirements"] as? [String: Any] {
            p.minimum = pc["minimum"] as? String ?? ""
            p.recommended = pc["recommended"] as? String ?? ""
        }
        p.languages = d["supported_languages"] as? String ?? ""
        p.metacritic = (d["metacritic"] as? [String: Any])?["score"] as? Int
        p.dlc = d["dlc"] as? [Int] ?? []
        return p
    }

    static func parse(reviews data: Data) -> Reviews? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let q = root["query_summary"] as? [String: Any], let total = q["total_reviews"] as? Int, total > 0 else { return nil }
        return Reviews(label: q["review_score_desc"] as? String ?? "", positive: q["total_positive"] as? Int ?? 0, total: total)
    }

    static func parse(dlc data: Data, id: Int) -> DLC? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root[String(id)] as? [String: Any], entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any], let name = d["name"] as? String else { return nil }
        return DLC(id: id, name: name, price: price(d["price_overview"]), free: d["is_free"] as? Bool ?? false)
    }
}

/// Fetches and remembers store pages for the session. Requests are plain GETs with short timeouts.
@MainActor
final class StorePageCache {
    static let shared = StorePageCache()
    private var pages: [UInt32: StorePage] = [:]
    private var dlcs: [Int: StorePage.DLC] = [:]
    private var reviewCache: [UInt32: StorePage.Reviews] = [:]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        return URLSession(configuration: c)
    }()

    private nonisolated static func get(_ s: String) async -> Data? {
        guard let url = URL(string: s), let (data, r) = try? await session.data(from: url),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    func page(_ appid: UInt32) async -> StorePage? {
        if let p = pages[appid] { return p }
        guard let d = await Self.get("https://store.steampowered.com/api/appdetails?appids=\(appid)&l=schinese&cc=cn"),
              let page = StorePage.parse(details: d, appid: appid) else { return nil }
        pages[appid] = page
        return page
    }

    /// Fetched apart from the page: the reviews endpoint is the slowest one and must not hold the page back.
    func reviews(_ appid: UInt32) async -> StorePage.Reviews? {
        if let r = reviewCache[appid] { return r }
        guard let data = await Self.get("https://store.steampowered.com/appreviews/\(appid)?json=1&language=all&purchase_type=all&num_per_page=0&l=schinese"),
              let r = StorePage.parse(reviews: data) else { return nil }
        reviewCache[appid] = r
        return r
    }

    func dlc(_ ids: [Int]) async -> [StorePage.DLC] {
        let missing = ids.filter { dlcs[$0] == nil }
        let fetched = await withTaskGroup(of: StorePage.DLC?.self) { group in
            for id in missing {
                group.addTask {
                    guard let data = await Self.get("https://store.steampowered.com/api/appdetails?appids=\(id)&l=schinese&cc=cn&filters=basic,price_overview")
                    else { return nil }
                    return StorePage.parse(dlc: data, id: id)
                }
            }
            return await group.reduce(into: [StorePage.DLC]()) { if let d = $1 { $0.append(d) } }
        }
        for d in fetched { dlcs[d.id] = d }
        return ids.compactMap { dlcs[$0] }
    }
}

struct StorePageView: View {
    let appid: UInt32
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    @EnvironmentObject var engine: EngineModel

    @State private var page: StorePage?
    @State private var failed = false
    @State private var about = AttributedString()
    @State private var dlc: [StorePage.DLC] = []
    @State private var reviews: StorePage.Reviews?
    @State private var selected = 0
    @State private var viewing: Int?
    @State private var showRequirements = false
    @State private var installing = false
    @State private var attempt = 0

    private var storeURL: URL { URL(string: "https://store.steampowered.com/app/\(appid)/") ?? URL(fileURLWithPath: "/") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button(action: onClose) {
                    Text("‹ 返回").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                if let page {
                    content(page)
                } else if failed {
                    HStack(spacing: 10) {
                        Text("商店页面没有加载出来。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button("重试") { attempt += 1 }.buttonStyle(.link).font(.system(size: 13))
                    }
                    .padding(.top, 20)
                } else {
                    skeleton
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .task(id: attempt) { await load() }
        .sheet(isPresented: $installing) {
            InstallSheet(appid: appid, name: page?.name ?? "App \(appid)") { installing = false }.environmentObject(engine)
        }
        .sheet(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let page, let i = viewing { ShotViewer(shots: page.shots, index: i) { viewing = nil } }
        }
    }

    /// Steam wraps list items in paragraphs; drop the blank lines that would leave between bullets.
    nonisolated private static func tidy(_ bb: String) -> String {
        bb.replacingOccurrences(of: "\\s*\\n\\s*\\[\\*\\]", with: "[*]", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    }

    private func load() async {
        failed = false
        guard let p = await StorePageCache.shared.page(appid) else {
            if !Task.isCancelled { failed = true }
            return
        }
        page = p
        let html = p.aboutHTML
        Task { reviews = await StorePageCache.shared.reviews(appid) }
        let text = await Task.detached(priority: .userInitiated) {
            EulaText.bbcode(Self.tidy(EulaText.bbcode(fromHTML: html)))
        }.value
        about = text
        let ids = Array(p.dlc.prefix(12))
        if !ids.isEmpty { dlc = await StorePageCache.shared.dlc(ids) }
    }

    private var skeleton: some View {
        HStack(alignment: .top, spacing: 28) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.surface).frame(width: 460, height: 215)
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 220, height: 20)
                RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(height: 12)
                RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 300, height: 12)
            }
        }
    }

    @ViewBuilder private func content(_ p: StorePage) -> some View {
        HStack(alignment: .top, spacing: 28) {
            AsyncImage(url: URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appid)/header.jpg")) { phase in
                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(Theme.surface) }
            }
            .frame(width: 460, height: 215)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 12) {
                Text(p.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                Text(p.shortDescription).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                facts(p)
            }
        }
        actions(p)
        media(p)
        if !p.genres.isEmpty || !p.categories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "类型与特性")
                if !p.genres.isEmpty {
                    Text(p.genres.joined(separator: "  ·  ")).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.85))
                }
                if !p.categories.isEmpty {
                    Text(p.categories.joined(separator: "  ·  "))
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineSpacing(3)
                }
            }
        }
        if !about.characters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "关于这款游戏")
                Text(about).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.85))
                    .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { open($0); return .handled })
            }
        }
        requirements(p)
        if !dlc.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "可下载内容")
                ForEach(dlc) { d in
                    HStack {
                        Text(d.name).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(d.price?.final ?? (d.free ? "免费" : "")).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 5)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        Button("在 Steam 网页中打开") { open(storeURL) }.buttonStyle(.link).font(.system(size: 12))
    }

    private func facts(_ p: StorePage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("发行日期", p.releaseDate)
            fact("开发商", p.developers.joined(separator: "、"))
            fact("发行商", p.publishers.joined(separator: "、"))
            if let r = reviews {
                fact("用户评测", "\(r.label)（\(r.positive * 100 / r.total)% 好评，\(r.total) 篇）")
            }
            if let m = p.metacritic { fact("Metacritic", "\(m)") }
        }
    }

    @ViewBuilder private func fact(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 58, alignment: .leading)
                Text(value).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func actions(_ p: StorePage) -> some View {
        let app = engine.steamApps[appid]
        HStack(spacing: 14) {
            if let app {
                if let pr = engine.progress[appid], !pr.isInstalled {
                    Text(pr.total > 0 ? "下载中 \(Int(pr.fraction * 100))%" : "排队中").font(.system(size: 13)).foregroundStyle(Theme.text)
                } else if app.installed {
                    HStack(spacing: 7) {
                        StatusDot(color: Theme.ok)
                        Text("已安装").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    }
                    if app.sizeOnDisk > 0 { Text(bytes(app.sizeOnDisk)).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                } else {
                    actionButton("安装", prominent: true) { installing = true }
                        .disabled(engine.steam == nil || engine.busy)
                }
                Text("已在库中").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else {
                if let price = p.price {
                    if price.discount > 0 {
                        Text("-\(price.discount)%").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ok)
                        Text(price.initial).font(.system(size: 12)).strikethrough().foregroundStyle(Theme.tertiary)
                    }
                    Text(price.final).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    actionButton("加入购物车", prominent: true) { open(storeURL) }
                } else if p.isFree {
                    Text("免费").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    actionButton("免费开始", prominent: true) { open(storeURL) }
                } else if p.comingSoon {
                    Text("尚未发行").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Button("加入愿望单") { open(storeURL) }.buttonStyle(.link).font(.system(size: 12.5))
            }
        }
    }

    private func actionButton(_ title: String, prominent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func media(_ p: StorePage) -> some View {
        let items = p.movies.filter { $0.video != nil }.map { MediaItem.movie($0) } + p.shots.map { MediaItem.shot($0) }
        if !items.isEmpty {
            let index = min(selected, items.count - 1)
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Rectangle().fill(Color.black)
                    switch items[index] {
                    case .movie(let m):
                        if let url = m.video { MoviePlayer(url: url).id(url) }
                    case .shot(let s):
                        AsyncImage(url: s.full) { $0.image?.resizable().aspectRatio(contentMode: .fit) }
                            .onTapGesture { viewing = p.shots.firstIndex { $0.id == s.id } }
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 640)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            AsyncImage(url: item.thumb) { phase in
                                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(Theme.surface) }
                            }
                            .frame(width: 128, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay { if item.isMovie { Text("▶").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85)) } }
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(i == index ? Theme.accent : .clear, lineWidth: 1.5))
                            .opacity(i == index ? 1 : 0.7)
                            .onTapGesture { selected = i }
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func requirements(_ p: StorePage) -> some View {
        if !p.minimum.isEmpty || !p.recommended.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { showRequirements.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(showRequirements ? "▾" : "▸").font(.system(size: 10))
                        SectionLabel(text: "系统需求")
                    }
                    .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                if showRequirements {
                    HStack(alignment: .top, spacing: 40) {
                        if !p.minimum.isEmpty { requirementColumn(p.minimum) }
                        if !p.recommended.isEmpty { requirementColumn(p.recommended) }
                    }
                }
            }
        }
    }

    private func requirementColumn(_ html: String) -> some View {
        let text = EulaText.bbcode(Self.tidy(EulaText.bbcode(fromHTML: html)))
        return Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360, alignment: .leading).textSelection(.enabled)
    }
}

private enum MediaItem {
    case movie(StorePage.Movie)
    case shot(StorePage.Shot)

    var thumb: URL? {
        switch self {
        case .movie(let m): return m.thumbnail
        case .shot(let s): return s.thumb
        }
    }
    var isMovie: Bool { if case .movie = self { return true } else { return false } }
}

private struct MoviePlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) } else { Color.black }
        }
        .onAppear { if player == nil { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause(); player = nil }
    }
}

private struct ShotViewer: View {
    let shots: [StorePage.Shot]
    @State var index: Int
    let close: () -> Void

    init(shots: [StorePage.Shot], index: Int, close: @escaping () -> Void) {
        self.shots = shots
        _index = State(initialValue: index)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 10) {
            AsyncImage(url: shots[index].full) { phase in
                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) } else { Color.black }
            }
            .frame(minWidth: 960, minHeight: 540)
            HStack(spacing: 18) {
                Button("上一张") { index = (index + shots.count - 1) % shots.count }.keyboardShortcut(.leftArrow, modifiers: [])
                Text("\(index + 1) / \(shots.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                Button("下一张") { index = (index + 1) % shots.count }.keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .background(Color.black)
    }
}
