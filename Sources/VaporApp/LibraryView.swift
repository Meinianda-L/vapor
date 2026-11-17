import SwiftUI
import VaporKit

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    let destination: Destination
    @Binding var search: String
    @Binding var selection: UInt32?
    @EnvironmentObject var engine: EngineModel

    private var visible: [GameItem] {
        store.games.filter { destination.matches($0, shelves: engine.shelves) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        ScrollView {
            LibraryContent(title: destination.title(in: engine.shelves), games: visible, installs: store.installs,
                           search: $search, loading: store.loading, selection: $selection,
                           showsFavorites: destination.isPlainShelf)
        }
    }
}

enum LibrarySort: String, CaseIterable {
    case name, recent, playtime

    var label: String {
        switch self {
        case .name: return String(localized: "名称")
        case .recent: return String(localized: "最近游玩")
        case .playtime: return String(localized: "游玩时长")
        }
    }
}

/// Library page body: a large title, then recently played, installed and not-installed shelves.
struct LibraryContent: View {
    let title: String
    let games: [GameItem]
    let installs: [SteamInstall]
    @Binding var search: String
    var loading = false
    @Binding var selection: UInt32?
    /// Favourites get a shelf of their own, except in a collection or the hidden list.
    var showsFavorites = true
    @AppStorage("librarySort") private var sort = LibrarySort.name
    @EnvironmentObject var engine: EngineModel

    private static let recentLimit = 6
    private static let recentTileWidth: CGFloat = 160

    private struct Shelves {
        var favorites: [GameItem] = []
        var recent: [GameItem] = []
        var installed: [GameItem] = []
        var other: [GameItem] = []
    }
    @State private var shelves = Shelves()

    /// Sorting is cached in `shelves`; it reruns only when the games, sort, search or Steam data change,
    /// not on every engine publish (download progress ticks).
    private func rebuild() {
        let apps = engine.steamApps
        let sort = self.sort
        func last(_ g: GameItem) -> Int { apps[g.appid]?.lastPlayed ?? 0 }
        func minutes(_ g: GameItem) -> Int { apps[g.appid]?.minutesPlayed ?? 0 }
        func byName(_ a: GameItem, _ b: GameItem) -> Bool { a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        func ordered(_ items: [GameItem]) -> [GameItem] {
            let rank: (GameItem) -> Int
            switch sort {
            case .name: return items
            case .recent: rank = last
            case .playtime: rank = minutes
            }
            let ranked = items.map { (rank($0), $0) }
            return ranked.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : byName($0.1, $1.1) }.map(\.1)
        }
        var next = Shelves()
        if showsFavorites { next.favorites = ordered(games.filter { engine.isFavorite($0.appid) }) }
        next.installed = ordered(games.filter(\.installed))
        next.other = ordered(games.filter { !$0.installed })
        if sort == .name, search.isEmpty {
            let played = games.map { (last($0), $0) }.filter { $0.0 > 0 }
            next.recent = Array(played.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : byName($0.1, $1.1) }
                .prefix(Self.recentLimit).map(\.1))
        }
        shelves = next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .kerning(-0.6)
                        .foregroundStyle(Theme.text)
                    MetaLine(parts: ["\(games.filter(\.installed).count) 个已安装", String(localized: "共 \(games.count) 个")])
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                SortMenu(sort: $sort)
                SearchField(text: $search)
            }
            shelf(String(localized: "收藏夹"), shelves.favorites)
            recentShelf
            shelf(String(localized: "已安装"), shelves.installed)
            shelf(String(localized: "没有安装"), shelves.other)
        }
        .onAppear(perform: rebuild)
        .onChange(of: games) { rebuild() }
        .onChange(of: sort) { rebuild() }
        .onChange(of: search) { rebuild() }
        .onChange(of: engine.steamApps) { rebuild() }
        .onChange(of: engine.shelves) { rebuild() }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func shelf(_ name: String, _ items: [GameItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: name)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 176), spacing: 24, alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(items) { game in
                        GameTile(game: game, installs: installs, sort: sort)
                            .onTapGesture { selection = game.appid }
                    }
                }
            }
        }
    }

    /// One row of fixed-width tiles in a scroll view, so all of them stay reachable at any window width.
    @ViewBuilder private var recentShelf: some View {
        if !shelves.recent.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: String(localized: "最近游玩"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(shelves.recent) { game in
                            GameTile(game: game, installs: installs, sort: .recent, compact: true)
                                .frame(width: Self.recentTileWidth)
                                .onTapGesture { selection = game.appid }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

struct SortMenu: View {
    @Binding var sort: LibrarySort
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        Menu {
            Picker("", selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            (Text(engine.strings("Library_SortCollectionBy") ?? String(localized: "排序方式：")).foregroundStyle(Theme.secondary)
                + Text(sort.label).foregroundStyle(Theme.text)
                + Text(" \(Image(systemName: "chevron.up.chevron.down"))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary))
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairline))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            TextField(String(localized: "搜索"), text: $text).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairline))
    }
}

struct ArtworkView: View {
    let appid: UInt32
    let kind: Artwork.Kind
    let installs: [SteamInstall]
    @ObservedObject private var loader = ArtworkLoader.shared

    var body: some View {
        if let image = loader.image(appid: appid, kind: kind, installs: installs) {
            Image(nsImage: image).resizable()
        } else {
            Rectangle().fill(Color(white: 0.12))
        }
    }
}

struct GameTile: View {
    let game: GameItem
    let installs: [SteamInstall]
    /// Decides whether the subtitle leads with last played or playtime.
    var sort = LibrarySort.name
    /// Shortens the activity line where the shelf title already says what it is.
    var compact = false
    @EnvironmentObject var engine: EngineModel
    @State private var hovering = false
    @State private var sheet: GameSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(appid: game.appid, kind: .cover, installs: installs)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(game.installed ? 1 : 0.55)
                .shadow(color: .black.opacity(hovering ? 0.5 : 0.3), radius: hovering ? 12 : 6, y: hovering ? 8 : 3)
                .overlay(alignment: .bottom) {
                    if let p = engine.progress[game.appid], !p.isInstalled {
                        ProgressBar(fraction: p.fraction).padding(10)
                    }
                }
                .offset(y: hovering ? -3 : 0)
                .animation(.easeOut(duration: 0.18), value: hovering)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if game.installed && game.profile != nil { StatusDot(color: Theme.verdictColor(game.verdict)) }
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                if !downloading, let activity {
                    Text(activity).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu { GameMenu(game: game, sheet: $sheet) }
        .gameSheets(game, $sheet)
        .onHover { hovering = $0 }
    }

    private var downloading: Bool {
        if let p = engine.progress[game.appid], !p.isInstalled { return true }
        return false
    }

    private var subtitle: String {
        if let p = engine.progress[game.appid], !p.isInstalled {
            return p.total > 0 ? String(localized: "下载中 \(Int(p.fraction * 100))%") : String(localized: "排队中")
        }
        return platform
    }

    private var platform: String {
        if let p = game.profile, let r = p.ladder.first {
            return "\(Theme.verdictLabel(p.verdict)) · \(Theme.rendererLabel(r.renderer))"
        }
        if game.installed && game.hasMacBuild { return String(localized: "Mac 原生") }
        return game.windowsOnly ? "Windows" : "Mac · Windows"
    }

    private var activity: String? {
        guard let app = engine.steamApps[game.appid] else { return nil }
        if sort == .recent {
            guard app.lastPlayed > 0 else { return nil }
            return compact ? Self.ago(app.lastPlayed) : String(localized: "上次游玩 \(Self.ago(app.lastPlayed))")
        }
        guard app.minutesPlayed > 0 else { return nil }
        return app.minutesPlayed < 60 ? String(localized: "\(app.minutesPlayed) 分钟") : String(format: String(localized: "%.1f 小时"), Double(app.minutesPlayed) / 60)
    }

    /// Calendar days, so a game played last night reads "昨天" rather than "8 小时前".
    private static func ago(_ unix: Int) -> String {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(unix)))
        let c = cal.dateComponents([.year, .month, .day], from: from, to: cal.startOfDay(for: Date()))
        if let y = c.year, y > 0 { return String(localized: "\(y) 年前") }
        if let m = c.month, m > 0 { return String(localized: "\(m) 个月前") }
        switch c.day ?? 0 {
        case ..<1: return String(localized: "今天")
        case 1: return String(localized: "昨天")
        case let d: return String(localized: "\(d) 天前")
        }
    }
}
