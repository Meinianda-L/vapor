import SwiftUI
import VaporKit

private func day(_ d: Date?) -> String {
    guard let d else { return "" }
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(localized: "\(c.year ?? 0) 年 \(c.month ?? 0) 月 \(c.day ?? 0) 日")
}

/// Page chrome shared by the account pages: back link, title, a line under it.
private struct StorePageFrame<Content: View>: View {
    let title: String
    var subtitle = ""
    let onClose: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let onClose { StoreLink(title: String(localized: "‹ 返回"), action: onClose) }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                }
                content
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}

private struct Notice: View {
    let text: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if let retry { Button(String(localized: "重试"), action: retry).buttonStyle(.link).font(.system(size: 13)) }
        }
    }
}

// MARK: - Wishlist

/// The signed-in account's wishlist, read through the client.
struct WishlistView: View {
    let open: (URL) -> Void
    let openApp: (UInt32) -> Void
    var onClose: (() -> Void)?
    @EnvironmentObject var engine: EngineModel
    @ObservedObject private var data = StoreData.shared

    @State private var entries: [SteamUI.WishlistEntry] = []
    @State private var items: [UInt32: SteamUI.StoreItem] = [:]
    @State private var inCart: Set<UInt32> = []
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0
    @State private var filter = ""
    @State private var sort = Sort.rank
    @State private var working: Set<UInt32> = []
    @State private var problem: String?

    init(open: @escaping (URL) -> Void, openApp: @escaping (UInt32) -> Void, onClose: (() -> Void)? = nil) {
        self.open = open; self.openApp = openApp; self.onClose = onClose
    }

    enum Sort: String, CaseIterable {
        case rank = "你的排序", name = "名称", price = "价格", discount = "折扣", added = "添加日期", release = "发行日期", reviews = "用户评测"
    }

    private var shown: [SteamUI.WishlistEntry] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        let list = entries.filter { term.isEmpty || (items[$0.appid]?.name ?? "").localizedCaseInsensitiveContains(term) }
        let price = { (e: SteamUI.WishlistEntry) in items[e.appid]?.price?.finalCents ?? .max }
        switch sort {
        case .rank: return list.sorted { ($0.priority, $0.added ?? .distantPast) < ($1.priority, $1.added ?? .distantPast) }
        case .name: return list.sorted { (items[$0.appid]?.name ?? "").localizedStandardCompare(items[$1.appid]?.name ?? "") == .orderedAscending }
        case .price: return list.sorted { price($0) < price($1) }
        case .discount: return list.sorted { (items[$0.appid]?.price?.discount ?? 0) > (items[$1.appid]?.price?.discount ?? 0) }
        case .added: return list.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .release: return list.sorted { (items[$0.appid]?.releaseDate ?? .distantFuture) > (items[$1.appid]?.releaseDate ?? .distantFuture) }
        case .reviews: return list.sorted { (items[$0.appid]?.reviewPercent ?? 0) > (items[$1.appid]?.reviewPercent ?? 0) }
        }
    }

    var body: some View {
        StorePageFrame(title: String(localized: "愿望单"), subtitle: entries.isEmpty ? "" : String(localized: "\(entries.count) 款"), onClose: onClose) {
            if !engine.uiOnline {
                Notice(text: String(localized: "登录 Windows Steam 后可查看愿望单。"))
            } else if failed {
                Notice(text: String(localized: "愿望单没有加载出来。")) { attempt += 1 }
            } else if loading && entries.isEmpty {
                StoreSkeletonRows(count: 6)
            } else if entries.isEmpty {
                Notice(text: String(localized: "愿望单里还没有游戏。"))
            } else {
                HStack(spacing: 16) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                        TextField(String(localized: "按名称筛选"), text: $filter).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                    .frame(maxWidth: 280)
                    Spacer()
                    Menu {
                        ForEach(Sort.allCases, id: \.self) { s in Button(s.rawValue) { sort = s } }
                    } label: { Text(String(localized: "排序：\(sort.rawValue)")).font(.system(size: 12.5)) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.bad) }
                VStack(spacing: 2) {
                    ForEach(shown, id: \.appid) { e in
                        if let item = items[e.appid] {
                            StoreRow(item: item, detail: detail(item, e), trailing: AnyView(actions(item))) { openApp(e.appid) }
                        }
                    }
                }
            }
        }
        .task(id: "\(engine.uiOnline)\(attempt)") { await load() }
    }

    private func detail(_ item: SteamUI.StoreItem, _ e: SteamUI.WishlistEntry) -> String {
        [item.releaseText, item.reviewLine, e.added.map { String(localized: "添加于 \(day($0))") } ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private func actions(_ item: SteamUI.StoreItem) -> some View {
        let purchasable = item.price?.purchaseRef != nil
        let busy = working.contains(item.appid)
        return HStack(spacing: 14) {
            StorePriceLabel(item: item)
            if purchasable {
                if inCart.contains(item.appid) {
                    Text(String(localized: "已在购物车")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    Button { addToCart(item) } label: {
                        Text(String(localized: "加入购物车")).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(busy ? 0.4 : 0.9))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
                    }
                    .buttonStyle(.plain).disabled(busy)
                }
            }
            StoreLink(title: String(localized: "移除")) { remove(item.appid) }.disabled(busy)
        }
    }

    private func load() async {
        guard engine.uiOnline else { return }
        loading = true
        failed = false
        defer { if !Task.isCancelled { loading = false } }
        do {
            let list = try await engine.ui.wishlist()
            guard !Task.isCancelled else { return }
            entries = list
            let found = try await data.items(list.map { .app($0.appid) }, engine.ui)
            guard !Task.isCancelled else { return }
            items = Dictionary(found.map { ($0.appid, $0) }, uniquingKeysWith: { a, _ in a })
            if let cart = try? await engine.ui.cart(), !Task.isCancelled {
                let lines = Set(cart.lines.map(\.item))
                inCart = Set(found.filter { $0.price?.purchaseRef.map(lines.contains) ?? false }.map(\.appid))
            }
        } catch {
            if !Task.isCancelled && entries.isEmpty { failed = true }
        }
    }

    private func addToCart(_ item: SteamUI.StoreItem) {
        guard let ref = item.price?.purchaseRef else { return }
        working.insert(item.appid)
        problem = nil
        Task {
            do { try await engine.ui.addToCart(ref); inCart.insert(item.appid) } catch { problem = String(localized: "没能加入购物车：\(error)") }
            working.remove(item.appid)
        }
    }

    private func remove(_ appid: UInt32) {
        working.insert(appid)
        problem = nil
        Task {
            do { try await engine.ui.removeFromWishlist(appid); entries.removeAll { $0.appid == appid } } catch { problem = String(localized: "没能从愿望单移除：\(error)") }
            working.remove(appid)
        }
    }
}

// MARK: - Cart

/// The account's cart, read through the client. Payment is the one step left to Steam's checkout page.
struct CartView: View {
    let open: (URL) -> Void
    let openApp: (UInt32) -> Void
    var onClose: (() -> Void)?
    @EnvironmentObject var engine: EngineModel
    @ObservedObject private var data = StoreData.shared

    @State private var cart: SteamUI.Cart?
    @State private var items: [SteamUI.StoreItemID: SteamUI.StoreItem] = [:]
    @State private var failed = false
    @State private var attempt = 0
    @State private var working: Set<String> = []
    @State private var problem: String?

    init(open: @escaping (URL) -> Void, openApp: @escaping (UInt32) -> Void, onClose: (() -> Void)? = nil) {
        self.open = open; self.openApp = openApp; self.onClose = onClose
    }

    var body: some View {
        StorePageFrame(title: String(localized: "购物车"), subtitle: cart.map { $0.lines.isEmpty ? "" : String(localized: "\($0.lines.count) 件物品") } ?? "", onClose: onClose) {
            if !engine.uiOnline {
                Notice(text: String(localized: "登录 Windows Steam 后可查看购物车。"))
            } else if failed {
                Notice(text: String(localized: "购物车没有加载出来。")) { attempt += 1 }
            } else if let cart {
                if cart.lines.isEmpty {
                    Notice(text: String(localized: "你的购物车是空的。"))
                } else {
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.bad) }
                    VStack(spacing: 2) { ForEach(cart.lines) { line(cart, $0) } }
                    Divider().overlay(Theme.hairline)
                    summary(cart)
                }
            } else {
                StoreSkeletonRows(count: 3)
            }
        }
        .task(id: "\(engine.uiOnline)\(attempt)") { await load() }
    }

    @ViewBuilder private func line(_ cart: SteamUI.Cart, _ l: SteamUI.CartLine) -> some View {
        let trailing = HStack(spacing: 14) {
            if !l.isValid { Text(String(localized: "无法购买")).font(.system(size: 12)).foregroundStyle(Theme.bad) }
            if l.isGift { Text(String(localized: "礼物")).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            Text(l.price).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.text.opacity(0.9))
            StoreLink(title: String(localized: "移除")) { remove(l) }.disabled(working.contains(l.id))
        }
        if let item = items[l.item] {
            StoreRow(item: item, detail: l.added.map { String(localized: "加入于 \(day($0))") } ?? "", trailing: AnyView(trailing)) {
                if item.appid != 0 { openApp(item.appid) }
            }
        } else {
            HStack {
                Text(l.item.kind == .bundle ? String(localized: "捆绑包 \(l.item.id)") : String(localized: "礼包 \(l.item.id)")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
        }
    }

    private func summary(_ cart: SteamUI.Cart) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "付款在 Steam 的结算页面中完成。")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                if !cart.isValid { Text(String(localized: "购物车里有无法购买的物品，请先移除。")).font(.system(size: 12)).foregroundStyle(Theme.bad) }
            }
            Spacer()
            Text(String(localized: "预计总额")).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            Text(cart.subtotal).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            StoreAccentButton(title: String(localized: "前往结算"), enabled: cart.isValid && SteamUI.checkoutURL != nil) {
                if let url = SteamUI.checkoutURL { open(url) }
            }
        }
        .padding(.top, 4)
    }

    private func load() async {
        guard engine.uiOnline else { return }
        failed = false
        do {
            let c = try await engine.ui.cart()
            guard !Task.isCancelled else { return }
            cart = c
            let found = try await data.items(c.lines.map(\.item), engine.ui)
            guard !Task.isCancelled else { return }
            items = Dictionary(found.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            if !Task.isCancelled && cart == nil { failed = true }
        }
    }

    private func remove(_ l: SteamUI.CartLine) {
        working.insert(l.id)
        problem = nil
        Task {
            do {
                try await engine.ui.removeFromCart(l.id)
                cart = try await engine.ui.cart()
            } catch { problem = String(localized: "没能移除：\(error)") }
            working.remove(l.id)
        }
    }
}

// MARK: - Account

/// 账户详情: who is signed in, the wallet and its country. Read-only.
struct AccountView: View {
    let open: (URL) -> Void
    let openApp: (UInt32) -> Void
    var onClose: (() -> Void)?
    @EnvironmentObject var engine: EngineModel

    @State private var wallet: SteamUI.Wallet?
    @State private var failed = false
    @State private var attempt = 0

    init(open: @escaping (URL) -> Void, openApp: @escaping (UInt32) -> Void, onClose: (() -> Void)? = nil) {
        self.open = open; self.openApp = openApp; self.onClose = onClose
    }

    var body: some View {
        StorePageFrame(title: String(localized: "账户详情"), onClose: onClose) {
            if !engine.uiOnline {
                Notice(text: String(localized: "登录 Windows Steam 后可查看账户详情。"))
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    if let a = engine.account {
                        group(String(localized: "账户")) {
                            fact(String(localized: "个人资料名称"), a.persona)
                            fact(String(localized: "账户名称"), a.accountName)
                            fact("Steam ID", a.steamID)
                        }
                    }
                    if let w = wallet {
                        group(String(localized: "Steam 钱包")) {
                            fact(String(localized: "余额"), w.hasWallet ? w.balance : String(localized: "没有钱包"))
                            if w.pendingCents != 0 { fact(String(localized: "待处理"), w.pending) }
                            fact(String(localized: "国家/地区"), Locale(identifier: "zh_CN").localizedString(forRegionCode: w.country) ?? w.country)
                            if let t = w.lastTransaction { fact(String(localized: "最近一笔交易"), day(t)) }
                        }
                    } else if failed {
                        Notice(text: String(localized: "钱包信息没有加载出来。")) { attempt += 1 }
                    } else {
                        StoreSkeletonRows(count: 2)
                    }
                }
            }
        }
        .task(id: "\(engine.uiOnline)\(attempt)") {
            guard engine.uiOnline else { return }
            failed = false
            do {
                let w = try await engine.ui.wallet()
                if !Task.isCancelled { wallet = w }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: title)
            content()
        }
    }

    @ViewBuilder private func fact(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).frame(width: 96, alignment: .leading)
                Text(value).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.9)).textSelection(.enabled)
            }
        }
    }
}
