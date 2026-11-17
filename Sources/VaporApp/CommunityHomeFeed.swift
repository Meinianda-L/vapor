import SwiftUI
import VaporKit

/// Loads the home feed page by page; a new filter or a disappearing view cancels what is in flight.
@MainActor
final class CommunityFeedModel: ObservableObject {
    struct Filter: Hashable {
        var content = HomeContent.all
        var recent = false
        var mine = false
    }

    @Published private(set) var cards: [HomeCard] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var exhausted = false
    private var filter = Filter()
    private var page = 0
    private var task: Task<Void, Never>?

    func reload(_ filter: Filter) {
        task?.cancel()
        self.filter = filter
        cards = []; page = 0; exhausted = false; failed = false
        more()
    }

    func more() {
        guard !loading, !exhausted else { return }
        loading = true
        failed = false
        let filter = filter, next = page + 1
        task = Task {
            let result: [HomeCard]? = await Task.detached {
                let cookie = filter.mine ? await CommunitySession.cookieHeader() : nil
                let url = CommunityHomeClient.feed(filter.content, recent: filter.recent, page: next, anonymous: !filter.mine)
                guard let html = try? await CommunityClient.fetchString(url, cookie: cookie, ttl: 600) else { return nil }
                return CommunityHomeParser.cards(html: html)
            }.value
            guard !Task.isCancelled, filter == self.filter else { return }
            loading = false
            guard let result else { failed = true; return }
            let known = Set(cards.map(\.id))
            let fresh = result.filter { !known.contains($0.id) }
            page = next
            cards += fresh
            exhausted = fresh.isEmpty
        }
    }

    func cancel() { task?.cancel(); loading = false }
}

struct CommunityHomeFeed: View {
    var open: (URL) -> Void
    var openApp: (UInt32) -> Void
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineModel
    @StateObject private var feed = CommunityFeedModel()
    @State private var filter = CommunityFeedModel.Filter()
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            recent
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    CommunityChips(items: HomeContent.allCases.map { ($0, $0.title) }, selection: $filter.content)
                    Spacer(minLength: 16)
                    if signedIn {
                        CommunityChips(items: [(false, String(localized: "热门内容")), (true, String(localized: "我的游戏"))], selection: $filter.mine)
                    }
                    CommunityChips(items: [(false, String(localized: "最热门")), (true, String(localized: "最新"))], selection: $filter.recent)
                }
                content
            }
        }
        .task { signedIn = await CommunitySession.cookieHeader() != nil }
        .task(id: filter) { feed.reload(filter) }
        .onDisappear { feed.cancel() }
    }

    @ViewBuilder private var content: some View {
        if feed.cards.isEmpty {
            if feed.failed { CommunityFailure { feed.reload(filter) } }
            else if feed.loading { CommunitySkeleton(rows: 8) }
            else { CommunityNote(text: String(localized: "没有找到内容。")) }
        } else {
            CommunityMasonry {
                ForEach(feed.cards) { card in HomeCardView(card: card, open: open) }
            }
            if feed.failed { CommunityFailure { feed.more() } }
            else if !feed.exhausted { CommunityMoreButton(busy: feed.loading) { feed.more() } }
        }
    }

    @ViewBuilder private var recent: some View {
        let games = recentGames
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: String(localized: "最近玩过"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(games) { g in
                            Button { open(CommunityClient.hub(g.appid)) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ArtworkView(appid: g.appid, kind: .cover, installs: state.store.installs)
                                        .aspectRatio(2 / 3, contentMode: .fill)
                                        .frame(width: 96, height: 144)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    Text(g.name).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).frame(width: 96, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var recentGames: [GameItem] {
        let played = state.store.games.compactMap { g -> (GameItem, Int)? in
            let last = engine.steamApps[g.appid]?.lastPlayed ?? 0
            return last > 0 ? (g, last) : nil
        }
        return played.sorted { $0.1 > $1.1 }.prefix(14).map(\.0)
    }
}

struct HomeCardView: View {
    let card: HomeCard
    var open: (URL) -> Void

    private var kindLabel: String {
        switch card.kind {
        case .screenshot: return String(localized: "截图")
        case .artwork: return String(localized: "艺术作品")
        case .workshop: return String(localized: "创意工坊")
        case .guide: return String(localized: "指南")
        case .video: return String(localized: "视频")
        case .broadcast: return String(localized: "直播")
        }
    }

    var body: some View {
        Button { open(card.url) } label: {
            VStack(alignment: .leading, spacing: 9) {
                if card.kind == .guide {
                    guide
                } else {
                    CommunityThumb(url: card.image, aspect: card.kind == .artwork ? 4.0 / 3 : 16.0 / 9)
                    if !card.title.isEmpty {
                        Text(card.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                MetaLine(parts: [card.appName, kindLabel, card.viewers.isEmpty ? card.rating : card.viewers], size: 11.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var guide: some View {
        HStack(alignment: .top, spacing: 12) {
            CommunityThumb(url: card.image, aspect: 1).frame(width: 54)
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(3).multilineTextAlignment(.leading)
                if !card.excerpt.isEmpty { Text(card.excerpt).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(3).multilineTextAlignment(.leading) }
            }
        }
    }
}
