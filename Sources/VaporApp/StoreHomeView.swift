import SwiftUI
import VaporKit

/// Where the store front can lead without leaving it.
enum StoreRoute: Hashable {
    case search(String)
    case browse(title: String, query: SteamUI.StoreQuery)
    case wishlist, cart, account
}

/// Steam's store front, drawn natively: search with suggestions, the featured carousel, specials, the
/// new / top-selling / upcoming lists and browsing by tag. App pages open through `openApp`; the only
/// web page is checkout, which goes through `open`.
struct StoreHomeView: View {
    let open: (URL) -> Void
    let openApp: (UInt32) -> Void
    @EnvironmentObject var engine: EngineModel
    @ObservedObject private var data = StoreData.shared
    @State private var stack: [StoreRoute] = []

    init(open: @escaping (URL) -> Void, openApp: @escaping (UInt32) -> Void) {
        self.open = open
        self.openApp = openApp
    }

    var body: some View {
        Group {
            if let route = stack.last {
                routed(route)
            } else {
                home
            }
        }
        .background(Theme.background)
    }

    private func push(_ r: StoreRoute) { stack.append(r) }

    @ViewBuilder private func routed(_ route: StoreRoute) -> some View {
        let back = { _ = stack.popLast() }
        switch route {
        case .search(let term):
            StoreBrowseView(source: .search(term), open: open, openApp: openApp, onClose: back) { stack[stack.count - 1] = .search($0) }
                .id(route)
        case let .browse(title, query):
            StoreBrowseView(source: .query(title, query), open: open, openApp: openApp, onClose: back).id(route)
        case .wishlist:
            WishlistView(open: open, openApp: openApp, onClose: back)
        case .cart:
            CartView(open: open, openApp: openApp, onClose: back)
        case .account:
            AccountView(open: open, openApp: openApp, onClose: back)
        }
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header.zIndex(1)
                if data.homeFailed {
                    HStack(spacing: 10) {
                        Text(String(localized: "商店没有加载出来。")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button(String(localized: "重试")) { Task { await data.loadHome(engine, force: true) } }.buttonStyle(.link).font(.system(size: 13))
                    }
                } else {
                    FeaturedCarousel(items: data.shelves[.featured] ?? [], tagLine: { data.tagLine($0) }, openApp: openApp)
                    specials
                    StoreTabbedLists(data: data, openApp: openApp) { push(.browse(title: $0, query: $1)) }
                    if !data.tags.isEmpty { tagGrid }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .task(id: engine.uiOnline) { await data.loadHome(engine) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            Text(String(localized: "商店")).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
            StoreSearchField(openApp: openApp) { push(.search($0)) }
                .frame(maxWidth: 340)
            Spacer(minLength: 0)
            if engine.uiOnline {
                StoreLink(title: String(localized: "愿望单")) { push(.wishlist) }
                StoreLink(title: String(localized: "购物车")) { push(.cart) }
                StoreLink(title: String(localized: "账户")) { push(.account) }
            }
        }
    }

    @ViewBuilder private var specials: some View {
        let items = data.shelves[.specials] ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: String(localized: "特别优惠"))
                Spacer()
                if !data.publicOnly {
                    StoreLink(title: String(localized: "浏览更多")) { push(.browse(title: String(localized: "特别优惠"), query: .init(sort: .topSellers, discountedOnly: true))) }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 4), alignment: .leading, spacing: 20) {
                if items.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surface).aspectRatio(616.0 / 353.0, contentMode: .fit)
                    }
                } else {
                    ForEach(items.prefix(8)) { item in StoreTile(item: item) { openApp(item.appid) } }
                }
            }
        }
    }

    private var tagGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: String(localized: "按类型浏览"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(data.tags) { tag in
                    TagButton(title: tag.name) { push(.browse(title: tag.name, query: .init(sort: .topSellers, tagIDs: [tag.id]))) }
                }
            }
        }
    }
}

private struct TagButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(hovering ? Theme.text : Theme.text.opacity(0.8)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Carousel

private struct FeaturedCarousel: View {
    let items: [SteamUI.StoreItem]
    let tagLine: (SteamUI.StoreItem) -> String
    let openApp: (UInt32) -> Void
    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: String(localized: "精选和推荐"))
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 4).fill(Theme.surface).frame(height: 330)
            } else {
                let item = items[min(index, items.count - 1)]
                HStack(spacing: 0) {
                    StoreImage(url: item.capsule ?? item.header, corner: 0)
                        .aspectRatio(616.0 / 353.0, contentMode: .fit)
                        .onTapGesture { openApp(item.appid) }
                    side(item)
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                controls
            }
        }
    }

    private func side(_ item: SteamUI.StoreItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Array(item.screenshots.prefix(4).enumerated()), id: \.offset) { _, url in
                    StoreImage(url: url, corner: 2).aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            if !item.summary.isEmpty {
                Text(item.summary).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineSpacing(2).lineLimit(4)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                if !item.reviewLine.isEmpty {
                    Text(item.reviewLine).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                let tags = tagLine(item)
                if !tags.isEmpty { Text(tags).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1) }
            }
            StorePriceLabel(item: item, size: 14)
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { openApp(item.appid) }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            StoreLink(title: "‹") { index = (index + items.count - 1) % items.count }
            HStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    Rectangle().fill(i == index ? Theme.text.opacity(0.8) : Theme.hairline).frame(width: 16, height: 3)
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { index = i }
                }
            }
            StoreLink(title: "›") { index = (index + 1) % items.count }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - New / top sellers / upcoming

private struct StoreTabbedLists: View {
    @ObservedObject var data: StoreData
    let openApp: (UInt32) -> Void
    let browse: (String, SteamUI.StoreQuery) -> Void
    @State private var tab = 0

    private var tabs: [(String, StoreData.Shelf, SteamUI.StoreQuery)] {
        [(String(localized: "新品与热门"), .newReleases, .init(sort: .topSellers, releasedWithinDays: 30)),
         (String(localized: "热销商品"), .featured, .init(sort: .topSellers)),
         (String(localized: "即将推出"), .comingSoon, .init(sort: .topSellers, comingSoonOnly: true))]
    }

    var body: some View {
        let (title, shelf, query) = tabs[tab]
        let items = data.shelves[shelf] ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button { tab = i } label: {
                        VStack(spacing: 5) {
                            Text(tabs[i].0).font(.system(size: 13, weight: i == tab ? .semibold : .regular))
                                .foregroundStyle(i == tab ? Theme.text : Theme.secondary)
                            Rectangle().fill(i == tab ? Theme.accent : .clear).frame(height: 1.5)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !data.publicOnly { StoreLink(title: String(localized: "查看全部")) { browse(title, query) } }
            }
            Divider().overlay(Theme.hairline)
            if items.isEmpty {
                StoreSkeletonRows(count: 5)
            } else {
                VStack(spacing: 2) {
                    ForEach(items.prefix(10)) { item in
                        StoreRow(item: item, detail: detail(item, shelf)) { openApp(item.appid) }
                    }
                }
            }
        }
    }

    private func detail(_ item: SteamUI.StoreItem, _ shelf: StoreData.Shelf) -> String {
        let tags = data.tagLine(item)
        if shelf == .comingSoon { return [item.releaseText, tags].filter { !$0.isEmpty }.joined(separator: "  ·  ") }
        return [tags, item.reviewLabel].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}

// MARK: - Search field

/// The store's search box: suggestions as you type (debounced, stale replies dropped), Return for all results.
struct StoreSearchField: View {
    let openApp: (UInt32) -> Void
    let submit: (String) -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var term = ""
    @State private var hits: [SteamUI.StoreItem] = []
    @State private var showing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            TextField(String(localized: "搜索商店"), text: $term)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    let t = term.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    showing = false
                    submit(t)
                }
                .onExitCommand { showing = false; term = "" }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        .overlay(alignment: .topLeading) {
            if showing && focused && !hits.isEmpty { suggestions.offset(y: 34) }
        }
        .task(id: term) {
            let t = term.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { hits = []; showing = false; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await StoreData.shared.search(t, max: 8, engine) ?? []
            guard !Task.isCancelled, t == term.trimmingCharacters(in: .whitespaces) else { return }
            hits = found
            showing = true
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hits.prefix(8)) { item in
                SuggestionRow(item: item) { showing = false; openApp(item.appid) }
            }
        }
        .padding(4)
        .frame(width: 400, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

private struct SuggestionRow: View {
    let item: SteamUI.StoreItem
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            StoreImage(url: item.smallCapsule ?? item.header, corner: 2).frame(width: 92, height: 34)
            Text(item.name).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            Text(StorePriceLabel.text(item)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: - Search results and browsing

/// Search results or a browse list (tag, specials, new, upcoming) with sorting and pages.
/// Browsing pages on the server; search gets Steam's best 100 matches and pages them here.
struct StoreBrowseView: View {
    enum Source: Hashable {
        case search(String)
        case query(String, SteamUI.StoreQuery)
    }

    let source: Source
    let open: (URL) -> Void
    let openApp: (UInt32) -> Void
    var onClose: () -> Void = {}
    var research: (String) -> Void = { _ in }
    @EnvironmentObject var engine: EngineModel
    @ObservedObject private var data = StoreData.shared

    @State private var sort: SteamUI.StoreSort
    @State private var page = 0
    @State private var items: [SteamUI.StoreItem] = []
    @State private var total = 0
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0
    @State private var hits: [SteamUI.StoreItem] = []

    private static let perPage = 25

    init(source: Source, open: @escaping (URL) -> Void, openApp: @escaping (UInt32) -> Void, onClose: @escaping () -> Void = {},
         research: @escaping (String) -> Void = { _ in }) {
        self.source = source; self.open = open; self.openApp = openApp; self.onClose = onClose; self.research = research
        if case let .query(_, q) = source { _sort = State(initialValue: q.sort) } else { _sort = State(initialValue: .relevance) }
    }

    private var title: String {
        switch source {
        case .search(let t): return String(localized: "“\(t)”的搜索结果")
        case .query(let t, _): return t
        }
    }
    private var sorts: [(SteamUI.StoreSort, String)] {
        var list: [(SteamUI.StoreSort, String)] = [(.topSellers, String(localized: "热销")), (.newest, String(localized: "最新发行")), (.reviews, String(localized: "用户评测")),
                                                   (.priceAscending, String(localized: "价格从低到高")), (.priceDescending, String(localized: "价格从高到低"))]
        if case .search = source { list.insert((.relevance, "相关度"), at: 0); list.removeAll { $0.0 == .topSellers || $0.0 == .reviews } }
        return list
    }
    private var pageCount: Int { max(1, (total + Self.perPage - 1) / Self.perPage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StoreLink(title: String(localized: "‹ 返回"), action: onClose)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if total > 0 { Text(countLine).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                    Spacer()
                    Menu {
                        ForEach(sorts, id: \.0) { s in Button(s.1) { sort = s.0; page = 0 } }
                    } label: {
                        Text("排序：\(sorts.first { $0.0 == sort }?.1 ?? "")").font(.system(size: 12.5))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if case .search = source {
                    StoreSearchField(openApp: openApp, submit: research).frame(maxWidth: 340)
                }
                if failed {
                    HStack(spacing: 10) {
                        Text(engine.uiOnline ? String(localized: "没有加载出来。") : String(localized: "浏览商店需要 Windows Steam 在线。")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        if engine.uiOnline { Button(String(localized: "重试")) { attempt += 1 }.buttonStyle(.link).font(.system(size: 13)) }
                    }
                } else if loading && items.isEmpty {
                    StoreSkeletonRows(count: 8)
                } else if items.isEmpty {
                    Text(String(localized: "没有找到符合条件的结果。")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            StoreRow(item: item, detail: detail(item)) { openApp(item.appid) }
                        }
                    }
                    .opacity(loading ? 0.5 : 1)
                    pager
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .task(id: LoadKey(sort: sort, page: page, attempt: attempt)) { await load() }
    }

    private struct LoadKey: Hashable { let sort: SteamUI.StoreSort; let page: Int; let attempt: Int }

    private var countLine: String {
        if case .search = source, total > hits.count, hits.count > 0 { return "共 \(total) 个结果，显示最相关的 \(hits.count) 个" }
        return String(localized: "共 \(total) 个结果")
    }

    private func detail(_ item: SteamUI.StoreItem) -> String {
        [item.releaseText, data.tagLine(item), item.reviewLine].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private var pager: some View {
        HStack(spacing: 16) {
            Spacer()
            StoreLink(title: String(localized: "‹ 上一页")) { page -= 1 }.disabled(page == 0).opacity(page == 0 ? 0.35 : 1)
            Text(String(localized: "第 \(page + 1) / \(pageCount) 页")).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
            StoreLink(title: String(localized: "下一页 ›")) { page += 1 }.disabled(page + 1 >= pageCount).opacity(page + 1 >= pageCount ? 0.35 : 1)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func load() async {
        loading = true
        failed = false
        defer { if !Task.isCancelled { loading = false } }
        switch source {
        case .search(let term):
            if hits.isEmpty {
                guard let found = await data.search(term, max: 100, engine) else { if !Task.isCancelled { failed = true }; return }
                guard !Task.isCancelled else { return }
                hits = found
            }
            let sorted = Self.sorted(hits, by: sort)
            total = sorted.count
            let start = min(page * Self.perPage, sorted.count)
            items = Array(sorted[start..<min(start + Self.perPage, sorted.count)])
        case .query(_, var q):
            guard engine.uiOnline else { failed = true; return }
            q.sort = sort
            q.start = page * Self.perPage
            q.count = Self.perPage
            do {
                let result = try await data.query(q, engine.ui)
                guard !Task.isCancelled else { return }
                items = result.items
                total = result.total
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    /// Search hits arrive by relevance; other orders are applied to them here.
    static func sorted(_ list: [SteamUI.StoreItem], by sort: SteamUI.StoreSort) -> [SteamUI.StoreItem] {
        let price = { (i: SteamUI.StoreItem) -> Int64 in i.price?.finalCents ?? (i.isFree ? 0 : .max) }
        switch sort {
        case .priceAscending: return list.sorted { price($0) < price($1) }
        case .priceDescending: return list.sorted { (price($0) == .max ? -1 : price($0)) > (price($1) == .max ? -1 : price($1)) }
        case .newest: return list.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        case .reviews: return list.sorted { $0.reviewPercent > $1.reviewPercent }
        default: return list
        }
    }
}
