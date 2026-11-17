import SwiftUI
import VaporKit

/// A user page whose link names the user by vanity URL or "my": resolved to a steamID64, then drawn by the
/// profile, inventory, trade offer or editor view.
struct UserPageView: View {
    @EnvironmentObject var engine: EngineModel
    let ref: UserRef
    let section: UserSection
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var resolved: String?
    @State private var missing = false
    @State private var attempt = 0

    var body: some View {
        if let id = steamID {
            content(id)
        } else {
            CommunityFrame(title: nil, open: open, onBack: onClose) {
                if missing {
                    HStack(spacing: 10) {
                        Text(failureText).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        if case .vanity = ref { Button("重试") { missing = false; attempt += 1 }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text) }
                    }
                } else if case .me = ref {
                    CommunityNote(text: String(localized: "尚未登录 Steam。"))
                } else {
                    CommunitySkeleton(rows: 2)
                }
            }
            .task(id: attempt) { await resolve() }
        }
    }

    private var failureText: String { String(localized: "找不到这个用户，或 Steam 没有及时回应。") }

    private var steamID: String? {
        switch ref {
        case .id(let id): return id
        case .me: return engine.account?.steamID
        case .vanity: return resolved
        }
    }

    private func resolve() async {
        guard case .vanity(let name) = ref, resolved == nil else { return }
        let id = try? await VanityResolver.resolve(name)
        guard !Task.isCancelled else { return }
        if let id { resolved = id } else { missing = true }
    }

    @ViewBuilder private func content(_ id: String) -> some View {
        switch section {
        case .profile, .editProfile:
            ProfileView(steamID: id, open: open, openGame: { open(URL(string: "https://store.steampowered.com/app/\($0)/")!) }, onClose: onClose,
                        startEditing: section == .editProfile)
        case .inventory(let appid):
            InventoryView(steamID: id, appid: appid, open: open, onClose: onClose)
        case .tradeOffers(let sent):
            TradeOffersView(steamID: id, sent: sent, open: open, onClose: onClose)
        }
    }
}

/// Incoming or sent trade offers, read from the web session. Answering an offer happens in Steam's own trade window.
struct TradeOffersView: View {
    let steamID: String
    @State var sent: Bool
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(steamID: String, sent: Bool, open: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        self.steamID = steamID; _sent = State(initialValue: sent); self.open = open; self.onClose = onClose
    }

    var body: some View {
        CommunityFrame(title: String(localized: "交易报价"), open: open, onBack: onClose) {
            TextTabs(items: [(false, String(localized: "收到的")), (true, String(localized: "已发送的"))], selection: $sent)
            Loadable(id: sent, load: loader) { list in
                VStack(alignment: .leading, spacing: 0) {
                    if list.offers.isEmpty { CommunityNote(text: list.emptyNote ?? String(localized: "没有交易报价。")) }
                    ForEach(list.offers) { offer in card(offer) }
                    if !list.offers.isEmpty {
                        Text("回应报价需要在 Steam 的交易窗口中进行，Vapor 暂不支持。")
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.top, 14)
                    }
                }
            }
        }
    }

    private var loader: @Sendable () async throws -> TradeOfferList {
        let id = steamID, sent = sent
        return {
            guard let cookie = await CommunitySession.cookieHeader() else { throw URLError(.userAuthenticationRequired) }
            let url = URL(string: "https://steamcommunity.com/profiles/\(id)/tradeoffers/\(sent ? "sent/" : "")?l=schinese")!
            return TradeOfferParser.list(html: try await CommunityClient.fetchString(url, cookie: cookie, ttl: 60))
        }
    }

    private func card(_ offer: TradeOffer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .center, spacing: 12) {
                CommunityAvatar(url: offer.avatar, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.partner).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    if let status = offer.status { Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                }
            }
            if !offer.message.isEmpty { Text(offer.message).font(.system(size: 12.5)).foregroundStyle(Theme.secondary) }
            ForEach(Array(offer.sides.enumerated()), id: \.offset) { _, side in
                VStack(alignment: .leading, spacing: 6) {
                    Text(side.header).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    if side.items.isEmpty {
                        Text("无").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48, maximum: 48), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(Array(side.items.enumerated()), id: \.offset) { _, item in
                                CommunityThumb(url: item.image, aspect: 1, radius: 3).help(item.title)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}
