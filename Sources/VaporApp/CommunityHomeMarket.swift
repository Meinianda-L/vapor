import SwiftUI
import VaporKit

/// 市场: popular and searched listings of the Community Market, read-only.
struct CommunityMarketTab: View {
    private struct Query: Hashable {
        var appid: UInt32?
        var text = ""
        var page = 1
    }

    @State private var query = Query()
    @State private var draft = ""
    @State private var item: MarketItem?
    private static let pageSize = 20

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 18) {
                Button { self.item = nil } label: { Text("‹ 市场").font(.system(size: 12.5)).foregroundStyle(Theme.secondary) }.buttonStyle(.plain)
                MarketItemView(item: item)
            }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                CommunityChips(items: [(UInt32?.none, "全部游戏")] + MarketClient.games.map { (UInt32?.some($0.appid), $0.name) },
                               selection: Binding(get: { query.appid }, set: { query = Query(appid: $0, text: query.text) }))
                Spacer(minLength: 0)
                CommunitySearchField(prompt: "搜索市场物品", text: $draft) {
                    query = Query(appid: query.appid, text: draft.trimmingCharacters(in: .whitespaces))
                }
            }
            Loadable(id: query, rows: 10, load: loader(query)) { page in
                VStack(alignment: .leading, spacing: 0) {
                    if page.items.isEmpty { CommunityNote(text: "没有找到物品。") }
                    ForEach(Array(page.items.enumerated()), id: \.element.id) { i, it in
                        if i > 0 { Divider().overlay(Theme.hairline) }
                        Button { item = it } label: { row(it) }.buttonStyle(.plain)
                    }
                    if page.total > Self.pageSize {
                        CommunityPager(page: query.page, pageCount: (page.total + Self.pageSize - 1) / Self.pageSize) { query.page = $0 }
                    }
                    if page.items.first?.priceText.hasPrefix("$") == true {
                        Text("列表价格以美元显示，物品详情以人民币显示。").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).padding(.top, 10)
                    }
                }
            }
        }
    }

    private func loader(_ q: Query) -> @Sendable () async throws -> MarketPage {
        let url = MarketClient.search(query: q.text, appid: q.appid, start: (q.page - 1) * Self.pageSize, count: Self.pageSize)
        return {
            let cookie = await CommunitySession.cookieHeader()
            guard let page = MarketParser.page(json: try await CommunityClient.fetch(url, cookie: cookie, ttl: 120)) else { throw URLError(.cannotParseResponse) }
            return page
        }
    }

    private func row(_ it: MarketItem) -> some View {
        HStack(spacing: 14) {
            CommunityThumb(url: it.icon(), aspect: 1, radius: 4).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(it.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(MarketItemView.color(it.nameColor) ?? Theme.text).lineLimit(1)
                MetaLine(parts: [it.appName, it.type], size: 11.5)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(it.priceText).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).monospacedDigit()
                Text("\(it.sellListings.formatted()) 件在售").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct MarketItemView: View {
    let item: MarketItem

    static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        let c = Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
        return hex.lowercased() == "d2d2d2" ? nil : c
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            CommunityThumb(url: item.icon(size: 256), aspect: 1, radius: 6)
                .frame(width: 200)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Self.color(item.nameColor) ?? Theme.text)
                    MetaLine(parts: [item.appName, item.type], size: 12.5)
                }
                Loadable(id: item.id, rows: 3, load: loader) { price in
                    VStack(alignment: .leading, spacing: 14) {
                        stat("最低售价", price.lowest ?? "—")
                        stat("中位价格", price.median ?? "—")
                        stat("24 小时成交量", price.volume.map { "\($0) 件" } ?? "—")
                        stat("在售数量", "\(item.sellListings.formatted()) 件")
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var loader: @Sendable () async throws -> MarketPrice {
        let url = MarketClient.priceOverview(appid: item.appid, hashName: item.hashName)
        return {
            guard let p = MarketParser.price(json: try await CommunityClient.fetch(url, ttl: 120)) else { throw URLError(.cannotParseResponse) }
            return p
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text).monospacedDigit()
        }
    }
}
