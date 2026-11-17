import SwiftUI
import VaporKit

struct PointsShopView: View {
    @EnvironmentObject var engine: EngineModel
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
    @State private var points: Int64?
    @State private var redeeming: RewardItem?

    var body: some View {
        CommunityFrame(title: String(localized: "点数商店"), open: open, onBack: onClose) {
            Text(points.map { String(localized: "你的点数：\($0.formatted())") } ?? String(localized: "正在读取点数余额…"))
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).monospacedDigit()
            if failed {
                HStack(spacing: 10) {
                    Text("没有加载出来。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Button("重试") { failed = false; Task { await load(reset: true) } }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                }
            } else if !started {
                CommunitySkeleton(rows: 5)
            } else if items.isEmpty {
                CommunityNote(text: String(localized: "这款游戏的点数商店没有物品。"))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        CommunityThumb(url: item.image, aspect: 1)
                        Text(item.title.isEmpty ? item.name : item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                        HStack {
                            Text("\(item.cost.formatted()) 点").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
                            Spacer(minLength: 0)
                            Button("兑换") { redeeming = item }.buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            if cursor != nil {
                Button(more ? String(localized: "正在加载…") : String(localized: "加载更多")) { Task { await load(reset: false) } }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text).disabled(more)
            }
        }
        .task(id: appid) { await load(reset: true) }
        .task { await loadPoints() }
        .sheet(item: $redeeming) { item in
            RedeemSheet(item: item, points: points) { await loadPoints() } dismiss: { redeeming = nil }
                .environmentObject(engine)
        }
    }

    private func loadPoints() async {
        guard engine.uiOnline else { return }
        let ui = engine.ui
        let summary = try? await ui.pointsSummary()
        if !Task.isCancelled, let summary { points = summary.points }
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

/// Shows what a reward costs and what is left before anything is spent.
private struct RedeemSheet: View {
    @EnvironmentObject var engine: EngineModel
    let item: RewardItem
    let points: Int64?
    let redeemed: () async -> Void
    let dismiss: () -> Void

    @State private var working = false
    @State private var done = false
    @State private var problem: String?

    private var affordable: Bool { points.map { $0 >= Int64(item.cost) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("兑换 \(item.title.isEmpty ? item.name : item.title)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 6) {
                line(String(localized: "所需点数"), "\(item.cost.formatted())")
                line(String(localized: "当前余额"), points.map { $0.formatted() } ?? String(localized: "读取中"))
                if let points { line(String(localized: "兑换后余额"), (points - Int64(item.cost)).formatted()) }
            }
            if !affordable, points != nil { Text("点数不足。").font(.system(size: 12.5)).foregroundStyle(Theme.warn) }
            if let problem { Text(problem).font(.system(size: 12.5)).foregroundStyle(Theme.warn) }
            if done { Text("已兑换。").font(.system(size: 12.5)).foregroundStyle(Theme.ok) }
            HStack(spacing: 18) {
                Spacer()
                Button(done ? String(localized: "完成") : String(localized: "取消"), action: dismiss).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                if !done {
                    Button(working ? String(localized: "正在兑换…") : String(localized: "确认兑换")) { Task { await redeem() } }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(affordable && !working ? Theme.accent : Theme.tertiary).disabled(!affordable || working)
                }
            }
        }
        .padding(24).frame(width: 380).background(Theme.background).preferredColorScheme(.dark)
    }

    private func line(_ a: String, _ b: String) -> some View {
        HStack { Text(a).foregroundStyle(Theme.secondary); Spacer(); Text(b).foregroundStyle(Theme.text).monospacedDigit() }
            .font(.system(size: 13))
    }

    private func redeem() async {
        working = true
        problem = nil
        defer { working = false }
        do {
            try await engine.ui.redeemPoints(defid: item.id, expectedCost: item.cost)
            done = true
            await redeemed()
        } catch {
            problem = String(localized: "兑换没有成功，点数没有变化或价格已变动。")
        }
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
        case .user(let ref, let section): UserPageView(ref: ref, section: section, open: open, onClose: onClose)
        }
    }
}
