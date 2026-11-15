import SwiftUI
import VaporKit

enum Destination: Hashable {
    case store, downloads, friends, all, installed, windows, mac, hidden, runtimes, settings
    case collection(String)

    var title: String {
        switch self {
        case .hidden: return "隐藏的游戏"
        case .collection: return "收藏"
        case .store: return "商店"
        case .downloads: return "下载"
        case .friends: return "好友"
        case .all: return "所有游戏"
        case .installed: return "已安装"
        case .windows: return "Windows 游戏"
        case .mac: return "Mac 原生"
        case .runtimes: return "运行时"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .store: return "bag"
        case .downloads: return "arrow.down.circle"
        case .friends: return "person.2"
        case .all: return "square.grid.2x2"
        case .installed: return "internaldrive"
        case .windows: return "pc"
        case .mac: return "macbook"
        case .hidden: return "eye.slash"
        case .collection: return "folder"
        case .runtimes: return "cpu"
        case .settings: return "gearshape"
        }
    }

    /// The collection's own name where it has one.
    func title(in shelves: SteamUI.Shelves?) -> String {
        if case let .collection(id) = self, let c = shelves?.collections.first(where: { $0.id == id }) { return c.name }
        return title
    }

    /// Everything but a collection or the hidden list: where favourites get their own shelf.
    var isPlainShelf: Bool {
        switch self {
        case .hidden, .collection: return false
        default: return true
        }
    }

    /// Hidden games only show up under 隐藏的游戏.
    func matches(_ g: GameItem, shelves: SteamUI.Shelves?) -> Bool {
        let hidden = shelves?.hidden.contains(g.appid) ?? false
        switch self {
        case .hidden: return hidden
        case let .collection(id): return !hidden && shelves?.collections.first { $0.id == id }?.apps.contains(g.appid) == true
        case .installed: return !hidden && g.installed
        case .windows: return !hidden && g.windowsOnly
        case .mac: return !hidden && g.hasMacBuild
        default: return !hidden
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var store = LibraryStore()
    let engine = EngineModel()
    /// Created at launch so the store is already loaded (and signed in) when it is opened.
    let storeModel = StoreModel()
    @Published var destination: Destination? = .all
    /// The game whose page is open; looked up in the library on every render so it stays current.
    @Published var selectedID: UInt32?
    @Published var search = ""
    /// The game whose Properties sheet is open.
    @Published var properties: UInt32?
}

struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: EngineModel
    @State private var rescan: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
        self.store = state.store
        self.engine = state.engine
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state, store: store)
                .frame(width: 216)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .background(Theme.background)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .environmentObject(engine)
        .environmentObject(state)
        .sheet(item: Binding(get: { state.properties.map { PropertiesRef(id: $0) } }, set: { state.properties = $0?.id })) { ref in
            PropertiesSheet(appid: ref.id) { state.properties = nil }.environmentObject(engine)
        }
        .alert(item: $engine.alert) { a in
            switch a {
            case .nativeSteamRunning:
                return Alert(title: Text("需要先退出 Mac 版 Steam"),
                             message: Text("同一个账号不能同时在两个 Steam 客户端在线。退出 Mac 版 Steam 后再试一次。"),
                             primaryButton: .default(Text("退出 Mac 版 Steam")) { engine.quitNativeSteam() },
                             secondaryButton: .cancel(Text("取消")))
            case let .message(m):
                return Alert(title: Text(m))
            }
        }
        .sheet(item: Binding(get: { engine.pendingStep.map(PendingStep.init) },
                             set: { if $0 == nil { engine.dismissInstall() } })) { step in
            InstallFlowSheet(run: step.run, onClose: { engine.dismissInstall() }).environmentObject(engine)
        }
        .sheet(isPresented: Binding(get: { engine.uninstallRequest != nil },
                                    set: { if !$0, engine.uninstallRequest != nil { engine.answerUninstall(false) } })) {
            UninstallSheet(appid: engine.uninstallRequest?.count == 1 ? engine.uninstallRequest?.first : nil,
                           names: uninstallNames, confirm: { engine.answerUninstall(true) }, dismiss: { engine.answerUninstall(false) })
        }
        .task(id: engine.uiOnline) { if engine.uiOnline { await state.storeModel.link(to: engine.ui) } }
        .onChange(of: engine.steamApps, initial: true) { _, apps in store.merge(steamApps: Array(apps.values)) }
        .onChange(of: engine.progress) { old, new in
            // Downloads starting, finishing or going away change what is installed. A manifest caught
            // mid-write drops out for one poll, so rescan once the state has settled.
            guard old.keys != new.keys || new.contains(where: { $0.value.isInstalled != old[$0.key]?.isInstalled }) else { return }
            // A download that just finished reports its manifest as complete, so rescan now; otherwise
            // the page would offer 安装 until the delay ran out.
            let finished = new.contains { $0.value.isInstalled && old[$0.key]?.isInstalled == false }
            rescan?.cancel()
            rescan = Task {
                if !finished { try? await Task.sleep(for: .seconds(2.5)) }
                if !Task.isCancelled { await store.load() }
            }
        }
    }

    private var uninstallNames: [String] {
        (engine.uninstallRequest ?? []).map { engine.steamApps[$0]?.name ?? "App \($0)" }
    }

    @ViewBuilder private var detail: some View {
        switch state.destination ?? .all {
        case .store:
            StoreView(store: state.storeModel, library: store) { game in
                state.destination = .all
                state.selectedID = game.appid
            }
        case .friends:
            FriendsView { steamID in
                state.storeModel.go("https://steamcommunity.com/profiles/\(steamID)/")
                state.destination = .store
            }
        case .downloads: DownloadsView(installs: store.installs)
        case .runtimes: RuntimesView()
        case .settings: SettingsView()
        case let d:
            if let id = state.selectedID, let game = store.games.first(where: { $0.appid == id }) {
                GameDetailView(game: game, installs: store.installs) { state.selectedID = nil }
            } else {
                LibraryView(store: store, destination: d, search: $state.search, selection: $state.selectedID)
            }
        }
    }
}

private struct PropertiesRef: Identifiable { let id: UInt32 }

private struct PendingStep: Identifiable {
    let run: SteamUI.Install
    var id: String { "\(run.appid)-\(run.step ?? "")" }
}

struct Sidebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: LibraryStore
    @EnvironmentObject var engine: EngineModel

    /// Collections made by hand that have games in them (a dynamic one is a saved filter).
    private var collections: [Destination] {
        let present = Set(store.games.map(\.appid))
        return (engine.shelves?.collections ?? []).filter { c in !c.dynamic && c.apps.contains(where: present.contains) }
            .map { .collection($0.id) }
    }

    private var hasHidden: Bool { store.games.contains { engine.isHidden($0.appid) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Steam", [.store, .downloads, .friends], counts: false)
            group("游戏库", [.all, .installed, .windows, .mac] + collections + (hasHidden ? [.hidden] : []), counts: true)
            group("Vapor", [.runtimes, .settings], counts: false)
            Spacer()
            AccountMenu(openProfile: { id in open("https://steamcommunity.com/profiles/\(id)/") },
                        openAccount: { open("https://store.steampowered.com/account/") })
        }
        .padding(.top, 52)          // clear the window's traffic lights
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .topTrailing) {
            // Level with the traffic lights.
            NotificationsButton { url in open(url.absoluteString) }
                .padding(.top, 12).padding(.trailing, 12)
        }
    }

    private func open(_ address: String) {
        state.storeModel.go(address)
        state.destination = .store
    }

    private func group(_ title: String, _ items: [Destination], counts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: title).padding(.horizontal, 20).padding(.bottom, 4)
            ForEach(items, id: \.self) { d in
                SidebarRow(destination: d, title: d.title(in: engine.shelves),
                           badge: d == .friends ? engine.unreadChats : 0,
                           count: counts ? store.games.filter { d.matches($0, shelves: engine.shelves) }.count : nil,
                           selected: state.destination == d) {
                    state.destination = d
                    state.selectedID = nil
                }
            }
        }
    }
}

struct SidebarRow: View {
    let destination: Destination
    let title: String
    var badge = 0
    let count: Int?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.8))
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Theme.accent))
                }
                if let count {
                    Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.07) : hovering ? Color.white.opacity(0.035) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovering = $0 }
    }
}
