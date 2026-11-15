import SwiftUI
import VaporKit

/// Bell for the sidebar header: Steam's notification tray in a popover.
struct NotificationsButton: View {
    @EnvironmentObject var engine: EngineModel
    let open: (URL) -> Void
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "bell")
                .font(.system(size: 13))
                .foregroundStyle(hovering || shown ? Theme.text : Theme.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(shown ? Color.white.opacity(0.07) : hovering ? Color.white.opacity(0.035) : .clear))
                .overlay(alignment: .topTrailing) {
                    if engine.unreadNotifications > 0 {
                        Text(engine.unreadNotifications > 99 ? "99+" : "\(engine.unreadNotifications)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Theme.accent))
                            .offset(x: 4, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(engine.strings("ViewNotifications") ?? "通知")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            NotificationsList(open: { url in shown = false; open(url) })
                .environmentObject(engine)
        }
    }
}

private struct NotificationsList: View {
    @EnvironmentObject var engine: EngineModel
    let open: (URL) -> Void
    @State private var items: [SteamUI.Notification]?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(engine.strings("QuickAccess_Tab_Notifications_Title") ?? "通知")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 40)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Spacer()
                Button("全部标为已读") { markRead() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(engine.unreadNotifications > 0 ? Theme.accent : Theme.tertiary)
                    .disabled(engine.unreadNotifications == 0)
            }
            .padding(.horizontal, 16).frame(height: 36)
        }
        .frame(width: 360)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let items, !items.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { n in NotificationRow(note: n, engine: engine, open: open) }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
        } else {
            Text(items == nil && !failed ? "" : failed ? "无法读取通知" : (engine.strings("QuickAccess_Tab_Notifications_None") ?? "没有新通知"))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity).frame(height: 96)
        }
    }

    /// Steam answers from its own tray, normally at once; a stuck connection should not hold the popover.
    private func load() async {
        guard engine.uiOnline else { failed = true; return }
        let ui = engine.ui
        let result = await withTaskGroup(of: [SteamUI.Notification]?.self) { group in
            group.addTask { try? await ui.notifications() }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        failed = result == nil
        items = result
    }

    private func markRead() {
        let ui = engine.ui
        Task {
            try? await ui.markNotificationsViewed()
            await load()
        }
    }
}

private struct NotificationRow: View {
    let note: SteamUI.Notification
    let engine: EngineModel
    let open: (URL) -> Void
    @State private var hovering = false

    private var url: URL? { note.page }

    var body: some View {
        Button { if let url { open(url) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: note.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(note.read ? Theme.secondary : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.summary(engine))
                        .font(.system(size: 12.5))
                        .foregroundStyle(note.read ? Theme.text.opacity(0.65) : Theme.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(Self.relative(note.time))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(hovering && url != nil ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { hovering = $0 }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    private static func relative(_ time: Int) -> String {
        formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(time)), relativeTo: Date())
    }
}

extension SteamUI.Notification {
    /// ESteamNotificationType values the tray shows.
    private enum Kind: Int {
        case gift = 2, comment, item, friendInvite, majorSale, preload, wishlist, tradeOffer
    }

    private var kind: Kind? { Kind(rawValue: type) }

    private var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    }

    private func appid(_ keys: String...) -> UInt32? {
        let p = payload
        for k in keys {
            if let n = p[k] as? Int { return UInt32(exactly: n) }
            if let s = p[k] as? String, let n = UInt32(s) { return n }
        }
        return nil
    }

    var symbol: String {
        switch kind {
        case .gift: return "gift"
        case .comment: return "bubble.left"
        case .item: return "shippingbox"
        case .friendInvite: return "person.badge.plus"
        case .majorSale, .wishlist: return "tag"
        case .preload: return "arrow.down.circle"
        case .tradeOffer: return "arrow.left.arrow.right"
        case nil: return "bell"
        }
    }

    /// The Steam page that handles this notification, where there is one.
    var page: URL? {
        switch kind {
        case .item: return URL(string: "https://steamcommunity.com/my/inventory/")
        case .gift: return URL(string: "https://steamcommunity.com/my/inventory/#pending_gifts")
        case .comment: return URL(string: "https://steamcommunity.com/my/commentnotifications/")
        case .friendInvite: return URL(string: "https://steamcommunity.com/my/friends/pending")
        case .wishlist: return URL(string: "https://store.steampowered.com/wishlist/")
        case .tradeOffer: return URL(string: "https://steamcommunity.com/my/tradeoffers/")
        default: return nil
        }
    }

    @MainActor func summary(_ engine: EngineModel) -> String {
        func name(_ id: UInt32?) -> String? { id.map { engine.steamApps[$0]?.name ?? "App \($0)" } }
        switch kind {
        case .gift:
            return engine.strings("Notification_GiftReceived_Body") ?? "你收到了一件礼物"
        case .comment:
            return "你收到了 \(count) 条新评论"
        case .item:
            let source = name(appid("source_appid")).map { "（来自 \($0)）" } ?? ""
            return "你获得了 \(count) 件新物品\(source)"
        case .friendInvite:
            return engine.strings("Notification_FriendInviteRollup_Body")?.replacingOccurrences(of: "%1$s", with: "\(count)")
                ?? "你收到了 \(count) 份新好友请求"
        case .majorSale:
            return "Steam 促销活动已开始"
        case .preload:
            return name(appid("app_id", "appid")).map { "\($0) 已预载完成" } ?? "游戏预载已完成"
        case .wishlist:
            return name(appid("app_id", "appid")).map { "愿望单中的 \($0) 正在特惠" } ?? "愿望单中有游戏正在特惠"
        case .tradeOffer:
            return "你收到了 \(count) 个新的交易报价"
        case nil:
            return "Steam 通知"
        }
    }
}
