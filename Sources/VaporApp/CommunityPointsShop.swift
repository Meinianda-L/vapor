import SwiftUI
import VaporKit

struct PointsShopView: View {
    let appid: UInt32
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var items: [RewardItem] = []
    @State private var total = 0
    @State private var fetched = 0
    @State private var cursor: String?
    @State private var started = false
    @State private var failed = false
    @State private var more = false

    var body: some View {
        CommunityFrame(title: "点数商店", open: open, onBack: onClose) {
            Text("这里只能浏览。兑换物品需要在 Steam 中使用点数完成，Vapor 暂不支持。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            if failed {
                HStack(spacing: 10) {
                    Text("没有加载出来。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Button("重试") { failed = false; Task { await load(reset: true) } }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                }
            } else if !started {
                CommunitySkeleton(rows: 5)
            } else if items.isEmpty {
                CommunityNote(text: "这款游戏的点数商店没有物品。")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        CommunityThumb(url: item.image, aspect: 1)
                        Text(item.title.isEmpty ? item.name : item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                        Text("\(item.cost.formatted()) 点").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                }
            }
            if cursor != nil {
                Button(more ? "正在加载…" : "加载更多") { Task { await load(reset: false) } }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text).disabled(more)
            }
        }
        .task(id: appid) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        more = true
        defer { more = false }
        let url = CommunityClient.rewards(appid, cursor: reset ? nil : cursor), id = appid
        let page = await Task.detached { () -> RewardPage? in
            guard let data = try? await CommunityClient.fetch(url) else { return nil }
            return RewardsParser.page(json: data, appid: id)
        }.value
        guard !Task.isCancelled else { return }
        started = true
        guard let page else { failed = true; return }
        items = reset ? page.items : items + page.items
        total = page.total
        fetched = (reset ? 0 : fetched) + page.fetched
        cursor = fetched >= page.total ? nil : page.cursor
    }
}

/// One entry point for `CommunityPage.page(for:)` results.
struct CommunityPageView: View {
    let page: CommunityPage
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        switch page {
        case .hub(let appid, let tab): CommunityHubView(appid: appid, tab: tab, open: open, onClose: onClose).id("\(appid)-\(tab.rawValue)")
        case .discussions(let appid, let forum, let topic): DiscussionsView(appid: appid, forum: forum, topic: topic, open: open, onClose: onClose)
        case .guides(let appid): GuidesView(appid: appid, open: open, onClose: onClose)
        case .workshop(let appid): WorkshopView(appid: appid, open: open, onClose: onClose)
        case .sharedFile(let id): SharedFileView(id: id, open: open, onClose: onClose)
        case .inventory(let steamID, let appid): InventoryView(steamID: steamID, appid: appid, open: open, onClose: onClose)
        case .pointsShop(let appid): PointsShopView(appid: appid, open: open, onClose: onClose)
        }
    }
}
