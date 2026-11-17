import SwiftUI
import VaporKit

struct InventoryView: View {
    let steamID: String
    var appid: UInt32?
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var selectedApp: UInt32?
    @State private var context: String?

    var body: some View {
        CommunityFrame(title: String(localized: "库存"), open: open, onBack: onClose) {
            Loadable(id: steamID, load: appsLoader) { apps in
                if apps.isEmpty {
                    CommunityNote(text: String(localized: "没有可显示的库存。库存为私密，或还没有任何带库存的游戏。"))
                } else {
                    let current = apps.first { $0.appid == (selectedApp ?? appid) } ?? apps[0]
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(apps) { app in
                                Button { selectedApp = app.appid; context = nil } label: {
                                    HStack {
                                        Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            .foregroundStyle(app.appid == current.appid ? Theme.accent : Theme.text)
                                        Spacer(minLength: 6)
                                        Text("\(app.count)").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
                                    }
                                    .padding(.vertical, 6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 190)
                        InventoryItems(steamID: steamID, app: current, context: context ?? current.contexts.first?.id ?? "2") { context = $0 }
                            .id(current.appid)
                    }
                }
            }
        }
    }

    private var appsLoader: @Sendable () async throws -> [InventoryApp] {
        let id = steamID
        return {
            let cookie = await CommunitySession.cookieHeader()
            return InventoryParser.apps(html: try await CommunityClient.fetchString(CommunityClient.inventoryPage(id), cookie: cookie, ttl: 120))
        }
    }
}

private struct InventoryItems: View {
    let steamID: String
    let app: InventoryApp
    let context: String
    let pick: (String) -> Void

    @State private var items: [InventoryItem] = []
    @State private var next: String?
    @State private var started = false
    @State private var failed = false
    @State private var more = false
    @State private var selected: String?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                if app.contexts.count > 1 {
                    TextTabs(items: app.contexts.map { ($0.id, $0.name) }, selection: Binding(get: { context }, set: pick))
                }
                if failed {
                    HStack(spacing: 10) {
                        Text("库存没有加载出来，可能需要重新登录 Steam。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button("重试") { failed = false; Task { await load(reset: true) } }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                } else if !started {
                    CommunitySkeleton(rows: 4)
                } else if items.isEmpty {
                    CommunityNote(text: String(localized: "这个库存是空的。"))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 10, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        Button { selected = item.id } label: { tile(item) }.buttonStyle(.plain)
                    }
                }
                if next != nil {
                    Button(more ? "正在加载…" : String(localized: "加载更多")) { Task { await load(reset: false) } }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text).disabled(more)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let item = items.first(where: { $0.id == selected }) { detail(item) }
        }
        .task(id: context) { items = []; next = nil; started = false; failed = false; selected = nil; await load(reset: true) }
    }

    private func load(reset: Bool) async {
        more = true
        defer { more = false }
        let after = reset ? nil : next
        let url = CommunityClient.inventory(steamID, appid: app.appid, context: context, after: after)
        let cookie = await CommunitySession.cookieHeader()
        let page = await Task.detached { () -> InventoryPage? in
            guard let data = try? await CommunityClient.fetch(url, cookie: cookie, ttl: 120) else { return nil }
            return InventoryParser.items(json: data)
        }.value
        guard !Task.isCancelled else { return }
        started = true
        guard let page else { failed = true; return }
        var merged = reset ? [] : items
        for i in page.items {
            if let k = merged.firstIndex(where: { $0.name == i.name && $0.type == i.type && $0.lines == i.lines }) { merged[k].count += i.count } else { merged.append(i) }
        }
        items = merged
        next = page.next
    }

    private func tile(_ item: InventoryItem) -> some View {
        VStack(spacing: 6) {
            CommunityThumb(url: item.icon, aspect: 1)
                .overlay(alignment: .bottomTrailing) {
                    if item.count > 1 { Text("×\(item.count)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text).padding(4) }
                }
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(item.id == selected ? Theme.accent : Theme.hairline))
            Text(item.name).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
    }

    private func detail(_ item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CommunityThumb(url: item.icon, aspect: 1)
            Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(hex(item.color) ?? Theme.text)
            if !item.type.isEmpty { Text(item.type).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            ForEach(Array(item.lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            if !item.tags.isEmpty { Text(item.tags.joined(separator: "、")).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
            MetaLine(parts: [item.tradable ? String(localized: "可交易") : String(localized: "不可交易"), item.marketable ? String(localized: "可上架市场") : String(localized: "不可上架市场")], size: 11.5)
        }
        .frame(width: 220, alignment: .leading)
    }

    private func hex(_ s: String) -> Color? {
        guard s.count == 6, let v = UInt32(s, radix: 16), s.lowercased() != "b0b0b0" else { return nil }
        return Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}
