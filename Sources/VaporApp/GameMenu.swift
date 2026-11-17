import SwiftUI
import VaporKit

/// A sheet a game menu can open; the tile and the game page each own one `@State` of this.
enum GameSheet: Identifiable {
    case install, uninstall, newCollection
    var id: Self { self }
}

extension View {
    /// Presents the sheets `GameMenu` asks for.
    func gameSheets(_ game: GameItem, _ sheet: Binding<GameSheet?>) -> some View {
        modifier(GameSheets(game: game, sheet: sheet))
    }
}

private struct GameSheets: ViewModifier {
    let game: GameItem
    @Binding var sheet: GameSheet?
    @EnvironmentObject var engine: EngineModel

    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { which in
            let close = { sheet = nil }
            switch which {
            case .install: InstallSheet(appid: game.appid, name: game.name, dismiss: close)
            case .uninstall:
                UninstallSheet(appid: game.appid, names: [game.name], confirm: { engine.uninstall(game.appid); close() }, dismiss: close)
            case .newCollection:
                NewCollectionSheet(confirm: { engine.newCollection($0, with: game.appid) }, dismiss: close)
            }
        }
    }
}

/// The library context menu of the Steam client, shared by the library tiles and the game page's gear.
struct GameMenu: View {
    let game: GameItem
    @Binding var sheet: GameSheet?
    @EnvironmentObject var engine: EngineModel
    @EnvironmentObject var app: AppState

    private enum Primary { case play, install, pause, resume }

    private var id: UInt32 { game.appid }
    private var viaWindowsSteam: Bool { game.installed && game.installKind == .wine }
    private var known: Bool { engine.steamApps[id] != nil }
    /// Collections, favourites and hidden games live in the Windows Steam client.
    private var canOrganize: Bool { engine.uiOnline && known }

    private var primary: Primary? {
        if let d = engine.downloads.first(where: { $0.appid == id && !$0.completed }) { return d.paused ? .resume : .pause }
        if viaWindowsSteam { return game.profile != nil ? .play : nil }
        return !game.installed && known ? .install : nil
    }

    private func t(_ key: String, _ fallback: String) -> String { engine.strings(key) ?? fallback }

    var body: some View {
        if let primary {
            switch primary {
            case .play:
                if engine.running.contains(id) {
                    Button(t("GameAction_Stop", String(localized: "停止"))) { engine.stopGame(id) }
                } else {
                    Button(t("GameAction_Play", String(localized: "开始游戏"))) { engine.play(game) }
                        .disabled(game.verdict == .blocked || engine.busy)
                }
            case .install:
                Button(t("GameAction_Install", String(localized: "安装")) + "…") { sheet = .install }.disabled(engine.steam == nil || engine.busy)
            case .pause: Button(t("GameAction_Pause", String(localized: "暂停"))) { engine.pause(id) }.disabled(!engine.uiOnline)
            case .resume: Button(t("GameAction_Resume", String(localized: "继续"))) { engine.resume(id) }.disabled(!engine.uiOnline)
            }
            Divider()
        }
        if engine.isFavorite(id) {
            Button(t("GameAction_RemoveFromFavorites", String(localized: "从收藏夹中移除"))) { engine.setFavorite(id, false) }.disabled(!canOrganize)
        } else {
            Button(t("GameAction_AddToFavorites", String(localized: "添加至收藏夹"))) { engine.setFavorite(id, true) }.disabled(!canOrganize)
        }
        Menu(t("GameAction_AddToCollection", String(localized: "添加至"))) {
            ForEach(engine.shelves?.collections.filter { !$0.dynamic } ?? []) { c in
                Toggle(c.name, isOn: Binding(get: { c.apps.contains(id) }, set: { engine.setInCollection(c.id, id, $0) }))
            }
            if engine.shelves?.collections.contains(where: { !$0.dynamic }) == true { Divider() }
            Button(t("GameAction_NewCollectionDialogTitle", String(localized: "新收藏")) + "…") { sheet = .newCollection }
        }
        .disabled(!canOrganize)
        Menu(t("GameAction_Manage", String(localized: "管理"))) {
            if game.installed, let dir = game.installDir {
                Button(t("GameAction_BrowseLocalFiles", String(localized: "浏览本地文件"))) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            }
            if viaWindowsSteam {
                Button(t("AppProperties_LocalFilesVerify_game", String(localized: "验证游戏文件的完整性"))) { engine.verify(id) }.disabled(!engine.uiOnline)
            }
            if engine.isHidden(id) {
                Button(t("GameAction_RemoveFromHidden", String(localized: "从隐藏中删除"))) { engine.setHidden(id, false) }.disabled(!canOrganize)
            } else {
                Button(t("GameAction_AddToHidden", String(localized: "隐藏此游戏"))) { engine.setHidden(id, true) }.disabled(!canOrganize)
            }
            if viaWindowsSteam {
                Divider()
                Button(t("GameAction_Uninstall", String(localized: "卸载")) + "…") { sheet = .uninstall }
            }
        }
        if known {
            Divider()
            Button(t("GameAction_GameProperties", String(localized: "属性…"))) { app.properties = id }
        }
    }
}
