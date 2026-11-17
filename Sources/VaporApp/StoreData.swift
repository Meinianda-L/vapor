import AppKit
import SwiftUI
import VaporKit

/// The store's lists for the session. Everything goes through the signed-in client (SteamUI+Store);
/// without it the store front falls back to Steam's public featured and search endpoints.
@MainActor
final class StoreData: ObservableObject {
    static let shared = StoreData()

    enum Shelf: CaseIterable { case featured, specials, newReleases, comingSoon }

    @Published private(set) var shelves: [Shelf: [SteamUI.StoreItem]] = [:]
    @Published private(set) var tags: [SteamUI.StoreTag] = []
    @Published private(set) var homeLoading = false
    @Published private(set) var homeFailed = false
    /// The home came from the public endpoints: no account prices, no tag browsing.
    @Published private(set) var publicOnly = false
    private(set) var tagNames: [Int: String] = [:]

    private var homeTime: Date?
    private var items: [SteamUI.StoreItemID: SteamUI.StoreItem] = [:]
    private var pages: [SteamUI.StoreQuery: (Date, SteamUI.StoreResults)] = [:]
    private var searches: [String: (Date, [SteamUI.StoreItem])] = [:]
    private static let lifetime: TimeInterval = 600

    static func query(_ shelf: Shelf) -> SteamUI.StoreQuery {
        switch shelf {
        case .featured: return .init(count: 10, sort: .topSellers)
        case .specials: return .init(count: 8, sort: .topSellers, discountedOnly: true)
        case .newReleases: return .init(count: 10, sort: .topSellers, releasedWithinDays: 30)
        case .comingSoon: return .init(count: 10, sort: .topSellers, comingSoonOnly: true)
        }
    }

    func loadHome(_ engine: EngineModel, force: Bool = false) async {
        if !force, let t = homeTime, Date().timeIntervalSince(t) < Self.lifetime, !publicOnly || !engine.uiOnline { return }
        guard !homeLoading else { return }
        homeLoading = true
        homeFailed = false
        defer { homeLoading = false }
        if engine.uiOnline {
            let ui = engine.ui
            await withTaskGroup(of: Void.self) { group in
                for shelf in Shelf.allCases {
                    group.addTask { @MainActor in
                        guard let page = try? await ui.storeQuery(Self.query(shelf), screenshots: shelf == .featured) else { return }
                        self.remember(page.items)
                        self.shelves[shelf] = page.items
                    }
                }
                group.addTask { @MainActor in
                    guard let tags = try? await ui.storeTags() else { return }
                    self.tags = Array(tags.prefix(30))
                    self.tagNames = Dictionary(tags.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                }
            }
            if !shelves.values.allSatisfy(\.isEmpty) {
                publicOnly = false
                homeTime = Date()
                return
            }
        }
        guard let data = await Self.get("https://store.steampowered.com/api/featuredcategories?cc=cn&l=\(SteamUI.storeLanguage)") else {
            if shelves.values.allSatisfy(\.isEmpty) { homeFailed = true }
            return
        }
        let lists = SteamUI.parseFeatured(data)
        shelves = [.featured: lists["top_sellers"] ?? [], .specials: lists["specials"] ?? [],
                   .newReleases: lists["new_releases"] ?? [], .comingSoon: lists["coming_soon"] ?? []]
        publicOnly = true
        homeTime = Date()
        homeFailed = shelves.values.allSatisfy(\.isEmpty)
    }

    func tagLine(_ item: SteamUI.StoreItem, limit: Int = 3) -> String {
        item.tagIDs.compactMap { tagNames[$0] }.prefix(limit).joined(separator: "、")
    }

    /// Items by id, cached; asks Steam in batches for the ones not seen yet.
    func items(_ ids: [SteamUI.StoreItemID], _ ui: SteamUI) async throws -> [SteamUI.StoreItem] {
        let missing = ids.filter { items[$0] == nil }
        var start = 0
        while start < missing.count {
            let batch = Array(missing[start..<min(start + 50, missing.count)])
            remember(try await ui.storeItems(batch))
            start += batch.count
        }
        return ids.compactMap { items[$0] }
    }

    func cached(_ id: SteamUI.StoreItemID) -> SteamUI.StoreItem? { items[id] }

    func query(_ q: SteamUI.StoreQuery, _ ui: SteamUI) async throws -> SteamUI.StoreResults {
        if let (t, page) = pages[q], Date().timeIntervalSince(t) < Self.lifetime { return page }
        let page = try await ui.storeQuery(q)
        remember(page.items)
        pages[q] = (Date(), page)
        return page
    }

    /// Search through the client when it is there (up to 100 matches), else the public search (up to 10).
    func search(_ term: String, max: Int, _ engine: EngineModel) async -> [SteamUI.StoreItem]? {
        let key = "\(max)|\(term)"
        if let (t, hits) = searches[key], Date().timeIntervalSince(t) < Self.lifetime { return hits }
        var hits: [SteamUI.StoreItem]?
        if engine.uiOnline { hits = try? await engine.ui.storeSearch(term, max: max) }
        if hits == nil {
            let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            hits = await Self.get("https://store.steampowered.com/api/storesearch/?term=\(q)&l=\(SteamUI.storeLanguage)&cc=CN")
                .map(SteamUI.parseStoreSearch)
        }
        if let hits {
            remember(hits)
            searches[key] = (Date(), hits)
        }
        return hits
    }

    private func remember(_ list: [SteamUI.StoreItem]) {
        for i in list where items[i.ref] == nil || !i.summary.isEmpty { items[i.ref] = i }
    }

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
}

// MARK: - Images

@MainActor
enum StoreImages {
    private static let cache = NSCache<NSURL, NSImage>()
    private static var loading: [URL: Task<NSImage?, Never>] = [:]

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    static func image(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let task = loading[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)) else { return nil }
            return NSImage(data: data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Store art cropped to fill its frame; a flat placeholder until it arrives.
struct StoreImage: View {
    let url: URL?
    var corner: CGFloat = 4
    @State private var image: NSImage?

    var body: some View {
        Rectangle().fill(Color(white: 0.12))
            .overlay {
                if let image = image ?? url.flatMap(StoreImages.cached) {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .task(id: url) {
                image = nil
                if let url { image = await StoreImages.image(url) }
            }
    }
}

// MARK: - Shared pieces

/// Discount, struck-through original and final price, the way Steam lines them up.
struct StorePriceLabel: View {
    let item: SteamUI.StoreItem
    var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 7) {
            if let p = item.price, p.discount > 0 {
                Text("-\(p.discount)%").font(.system(size: size - 1, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ok)
                if !p.original.isEmpty {
                    Text(p.original).font(.system(size: size - 1.5).monospacedDigit()).strikethrough().foregroundStyle(Theme.tertiary)
                }
            }
            Text(Self.text(item)).font(.system(size: size).monospacedDigit()).foregroundStyle(Theme.text.opacity(0.9))
        }
        .lineLimit(1)
    }

    static func text(_ item: SteamUI.StoreItem) -> String {
        if let p = item.price { return p.finalCents == 0 && item.isFree ? String(localized: "免费开玩") : p.final }
        if item.isFree { return String(localized: "免费开玩") }
        return item.comingSoon ? (item.releaseText.isEmpty ? String(localized: "即将推出") : item.releaseText) : ""
    }
}

/// A list row: small capsule, name, a detail line, price at the right edge.
struct StoreRow: View {
    let item: SteamUI.StoreItem
    var detail: String
    var trailing: AnyView?
    let action: () -> Void
    @State private var hovering = false

    init(item: SteamUI.StoreItem, detail: String, trailing: AnyView? = nil, action: @escaping () -> Void) {
        self.item = item; self.detail = detail; self.trailing = trailing; self.action = action
    }

    var body: some View {
        HStack(spacing: 14) {
            StoreImage(url: item.smallCapsule ?? item.header, corner: 3).frame(width: 154, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let trailing { trailing } else { StorePriceLabel(item: item) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// A capsule tile: art, name, price.
struct StoreTile: View {
    let item: SteamUI.StoreItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StoreImage(url: item.capsule ?? item.header)
                .aspectRatio(616.0 / 353.0, contentMode: .fit)
                .opacity(hovering ? 1 : 0.92)
            Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            StorePriceLabel(item: item, size: 12)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// "‹ 返回"-style text link used across the store pages.
struct StoreLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.secondary) }.buttonStyle(.plain)
    }
}

struct StoreAccentButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Theme.accent.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Quiet stand-in rows while a list loads.
struct StoreSkeletonRows: View {
    var count = 6
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 154, height: 58)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 220, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 140, height: 10)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

extension SteamUI.StorePrice {
    /// What goes into the cart for this price: its package, or its bundle.
    var purchaseRef: SteamUI.StoreItemID? {
        packageID.map { .init(.package, $0) } ?? bundleID.map { .init(.bundle, $0) }
    }
}

extension SteamUI.StoreItem {
    var reviewLine: String {
        guard !reviewLabel.isEmpty else { return "" }
        return reviewCount > 0 ? "\(reviewLabel)（\(reviewPercent)%）" : reviewLabel
    }
}
