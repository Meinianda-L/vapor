import SwiftUI
import VaporKit

/// The Steam client's library app page: hero with the logo where the game's art wants it, the play
/// bar (pinned once scrolled past), the link strip, then the activity feed beside the side sections.
struct GameDetailView: View {
    let game: GameItem
    let installs: [SteamInstall]
    var onBack: () -> Void = {}
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineModel
    @StateObject private var page = GamePageModel()
    @State private var showInfo = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Hero(game: game, installs: installs, logo: page.content.info?.logo, onBack: onBack)
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        if showInfo { GameInfoPanel(game: game, content: page.content).padding(.horizontal, 40).padding(.top, 22) }
                        LinkStrip(appid: game.appid, content: page.content, open: app.open)
                            .padding(.horizontal, 40).padding(.top, 18)
                        HStack(alignment: .top, spacing: 36) {
                            ActivityFeed(game: game, page: page, open: app.open)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            SideColumn(game: game, content: page.content, open: app.open) {
                                Task { await page.reloadNotes(game.appid, ui: engine.ui) }
                            }
                                .frame(width: 300)
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 28)
                        .padding(.bottom, 56)
                    }
                } header: {
                    PlayBar(game: game, content: page.content, showInfo: $showInfo)
                }
            }
        }
        .background(Theme.background)
        .task(id: "\(game.appid)-\(engine.uiOnline)") { await page.load(game.appid, engine: engine) }
    }
}

// MARK: - Hero

struct Hero: View {
    let game: GameItem
    let installs: [SteamInstall]
    var logo: SteamUI.LogoPosition?
    var onBack: () -> Void = {}

    var body: some View {
        // Fixed-size box with the image as an overlay, so .fill never widens the page.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .overlay { ArtworkView(appid: game.appid, kind: .hero, installs: installs).scaledToFill() }
            .clipped()
            .overlay { GeometryReader { g in placedLogo(in: g.size) } }
            .overlay(alignment: .topLeading) { BackButton(action: onBack).padding(.top, 20).padding(.leading, 24) }
    }

    /// Steam fits the logo into a box sized in percent of the hero and pins it to one of five spots;
    /// without that data it sits bottom-left.
    private func placedLogo(in size: CGSize) -> some View {
        let pin = logo?.pin ?? .bottomLeft
        let box = CGSize(width: size.width * (logo?.widthPct ?? 36) / 100, height: size.height * (logo?.heightPct ?? 50) / 100)
        let alignment: Alignment = switch pin {
        case .bottomLeft: .bottomLeading
        case .upperLeft: .topLeading
        case .centerCenter: .center
        case .upperCenter: .top
        case .bottomCenter: .bottom
        }
        return LogoView(game: game, installs: installs, alignment: alignment)
            .frame(width: box.width, height: box.height, alignment: alignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
    }
}

/// The game's logo image, or its name set in type when Steam has no logo for it.
private struct LogoView: View {
    let game: GameItem
    let installs: [SteamInstall]
    let alignment: Alignment
    @ObservedObject private var loader = ArtworkLoader.shared

    var body: some View {
        if let image = loader.image(appid: game.appid, kind: .logo, installs: installs) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Text(game.name)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .center || alignment == .top || alignment == .bottom ? .center : .leading)
        }
    }
}

/// What a launch is doing besides running the game (cloud sync, install scripts), in Steam's words.
struct LaunchStageLine: View {
    let appid: UInt32
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        if let stage = engine.launchStage[appid] {
            Text(stage).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }
}

/// Lets Steam itself start the game (its cloud sync, install scripts and playtime), where the renderer allows it.
struct SteamLaunchToggle: View {
    let game: GameItem
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        let on = engine.steamLaunched.contains(game.appid)
        let blocker = engine.steamLaunchBlocker(game)
        VStack(alignment: .leading, spacing: 6) {
            Toggle("由 Steam 启动（实验性）", isOn: Binding(get: { on }, set: { engine.setSteamLaunch($0, for: game.appid) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
            Text(on && blocker != nil ? String(localized: "\(blocker ?? "")仍由 Vapor 启动。")
                 : String(localized: "云存档、首次运行的安装脚本和游戏时间都交给 Steam。图形后端改用按程序的 DLL 覆盖，目前只支持 DXVK 和 WineD3D。"))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BackButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(hovering ? 0.6 : 0.4)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "返回"))
    }
}

// MARK: - Play bar

/// Steam's play bar: the one action that fits the game's state, the stat blocks, then 管理 / 信息 / 收藏.
struct PlayBar: View {
    let game: GameItem
    let content: GamePageModel.Content
    @Binding var showInfo: Bool
    @EnvironmentObject var engine: EngineModel
    @State private var sheet: GameSheet?
    @State private var confirmNativeLaunch = false

    private var id: UInt32 { game.appid }
    private var known: Bool { engine.steamApps[id] != nil }
    private var download: SteamUI.Download? { engine.downloads.first { $0.appid == id && !$0.completed } }
    private func t(_ key: String, _ fallback: String) -> String { engine.strings(key) ?? fallback }

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            VStack(alignment: .leading, spacing: 4) {
                primary
                LaunchStageLine(appid: id)
            }
            HStack(alignment: .center, spacing: 28) {
                ForEach(stats) { stat in StatBlock(stat: stat) }
            }
            .layoutPriority(-1)
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                Menu {
                    GameMenu(game: game, sheet: $sheet)
                } label: {
                    RoundIcon(symbol: "gearshape")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(t("GameAction_Manage", String(localized: "管理")))
                Button { showInfo.toggle() } label: { RoundIcon(symbol: "info", active: showInfo) }
                    .buttonStyle(.plain)
                    .help(showInfo ? t("GameAction_ViewDetails_Collapse", String(localized: "隐藏游戏详情")) : t("GameAction_ViewDetails", String(localized: "显示游戏详情")))
                let favorite = engine.isFavorite(id)
                Button { engine.setFavorite(id, !favorite) } label: { RoundIcon(symbol: favorite ? "star.fill" : "star", active: favorite) }
                    .buttonStyle(.plain)
                    .disabled(!engine.uiOnline || !known)
                    .help(favorite ? t("GameAction_UnFavorite", String(localized: "在收藏夹中")) : t("GameAction_Favorite", String(localized: "添加至收藏夹")))
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 78)
        .background(Theme.playBar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .gameSheets(game, $sheet)
        .task(id: engine.uiOnline ? id : nil) { await engine.loadCloudState(id) }
        .confirmationDialog("在 Mac 版 Steam 中启动 \(game.name)？", isPresented: $confirmNativeLaunch) {
            Button("启动") { launchInMacSteam() }
        } message: { Text("Mac 版 Steam 会登录同一账号，Windows Steam 随之下线，后台下载暂停。") }
    }

    @ViewBuilder private var primary: some View {
        if let d = download {
            if d.paused {
                PrimaryButton(title: t("GameAction_Resume", String(localized: "继续")), symbol: "arrow.down.to.line", enabled: engine.uiOnline) { engine.resume(id) }
            } else {
                PrimaryButton(title: t("GameAction_Pause", String(localized: "暂停")), symbol: "pause.fill", prominent: false, enabled: engine.uiOnline) { engine.pause(id) }
            }
        } else if engine.running.contains(id) {
            PrimaryButton(title: t("GameAction_Stop", String(localized: "停止")), symbol: "xmark", prominent: false) { engine.stopGame(id) }
        } else if game.installed && game.installKind == .wine {
            if engine.steamApps[id]?.displayStatus == GamePage.updateRequired {
                PrimaryButton(title: t("GameAction_Update", String(localized: "更新")), symbol: "arrow.down.to.line", enabled: engine.uiOnline && !engine.busy) { engine.queue(id) }
            } else {
                let launching = engine.busy && engine.lastLaunch == game.name
                PrimaryButton(title: launching ? t("GameAction_Launching", String(localized: "正在启动")) : t("GameAction_Play", String(localized: "开始游戏")), symbol: "play.fill",
                              enabled: game.profile != nil && game.verdict != .blocked && !engine.busy) { engine.play(game) }
            }
        } else if game.installed && !game.windowsOnly {
            // Mac Steam runs its own installs; signing it in takes the account from Windows Steam.
            PrimaryButton(title: t("GameAction_Play", String(localized: "开始游戏")), symbol: "play.fill") {
                if engine.isOnline { confirmNativeLaunch = true } else { launchInMacSteam() }
            }
        } else if game.installed {
            // Vapor runs games from Windows Steam's own install, which also keeps Steamworks working.
            PrimaryButton(title: t("GameAction_Install", String(localized: "安装")), symbol: "arrow.down.to.line", enabled: engine.steam != nil && !engine.busy) { sheet = .install }
                .help(String(localized: "已在 Mac 版 Steam 中安装；Vapor 从 Windows Steam 的安装运行游戏"))
        } else if game.windowsOnly || !game.hasMacBuild {
            PrimaryButton(title: t("GameAction_Install", String(localized: "安装")), symbol: "arrow.down.to.line", enabled: engine.steam != nil && !engine.busy) { sheet = .install }
        } else {
            Text("Mac 原生游戏，在 Mac 版 Steam 中安装").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private var stats: [StatBlock.Stat] {
        var out: [StatBlock.Stat] = []
        if let p = engine.progress[id], !p.isInstalled {
            let state = download?.paused == true ? t("DisplayStatus_DownloadPaused", String(localized: "下载已暂停"))
                : p.total > 0 ? t("DisplayStatus_Downloading", String(localized: "正在下载")) : t("DisplayStatus_DownloadQueued", String(localized: "位于下载队列中"))
            out.append(.init(id: "download", label: state,
                             value: p.total > 0 ? "\(Int(p.fraction * 100))% · \(bytes(p.downloaded)) / \(bytes(p.total))" : "—",
                             fraction: p.total > 0 ? p.fraction : nil))
        } else if !game.installed, let size = engine.downloadSize(id) {
            out.append(.init(id: "space", label: t("AppDetails_SectionTitle_DiskSpaceRequired", String(localized: "需要的空间")), value: bytes(size)))
        }
        let app = engine.steamApps[id]
        let last = [content.info?.lastPlayed, app.flatMap { $0.lastPlayed > 0 ? Date(timeIntervalSince1970: TimeInterval($0.lastPlayed)) : nil }]
            .compactMap { $0 }.max()
        if let last { out.append(.init(id: "last", label: t("AppDetails_SectionTitle_LastPlayed", String(localized: "最后运行日期")), value: GamePage.relative(last))) }
        let minutes = max(app?.minutesPlayed ?? 0, content.info?.playtimeMinutes ?? 0)
        if minutes > 0 {
            out.append(.init(id: "time", label: t("AppDetails_SectionTitle_PlayTime", String(localized: "游戏时间")), value: GamePage.playtime(minutes, engine.strings)))
        }
        // Like Steam: no achievements block for an uninstalled game nothing was unlocked in.
        if let a = content.achievements, !a.isEmpty, game.installed || a.contains(where: \.achieved) {
            let done = a.filter(\.achieved).count
            out.append(.init(id: "ach", label: t("AppDetails_SectionTitle_Achievements", String(localized: "成就")), value: "\(done)/\(a.count)",
                             fraction: Double(done) / Double(a.count)))
        }
        // Steam's live sync state once read (it also moves during Vapor's launch sync), else the page's snapshot.
        let live = engine.cloudStates[id].flatMap { $0.inUse ? engine.cloudLabel($0) : nil }
        if game.installed, live != nil || content.info?.cloudAvailable == true {
            out.append(.init(id: "cloud", label: t("AppDetails_SectionTitle_CloudStatus", String(localized: "云状态")),
                             value: live ?? content.info.map { GamePage.cloudStatus($0.cloudStatus, progress: $0.cloudProgress, engine.strings) } ?? ""))
        }
        return out
    }

    private func launchInMacSteam() {
        if let url = URL(string: "steam://rungameid/\(game.appid)") { NSWorkspace.shared.open(url) }
    }
}

/// One label-over-value block of the play bar, with Steam's thin bar under achievements and downloads.
struct StatBlock: View {
    struct Stat: Identifiable {
        let id: String
        let label: String
        let value: String
        var fraction: Double? = nil
    }
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(stat.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
            HStack(spacing: 8) {
                Text(stat.value).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text).lineLimit(1)
                if let f = stat.fraction { ProgressBar(fraction: f).frame(width: 64) }
            }
        }
        .fixedSize()
    }
}

private struct RoundIcon: View {
    let symbol: String
    var active = false
    @State private var hovering = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.text)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0.08)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// The big button at the left of the play bar. Accent for play and install, quiet for stop and pause.
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var prominent = true
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 26)
            .frame(minWidth: 150)
            .frame(height: 44)
            .foregroundStyle(!enabled ? Theme.secondary : prominent ? Color.black.opacity(0.88) : Theme.text)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        guard enabled else { return Theme.surface }
        return prominent ? Theme.accent.opacity(hovering ? 0.88 : 1) : Color.white.opacity(hovering ? 0.16 : 0.11)
    }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Vapor compatibility (renderer ladder)

/// The ladder of graphics back ends Vapor tries for this game; picking one makes it the launch default.
struct CompatibilitySheet: View {
    let game: GameItem
    let profile: GameProfile
    let dismiss: () -> Void
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vapor 兼容性").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    StatusDot(color: Theme.verdictColor(profile.verdict))
                    Text(Theme.verdictLabel(profile.verdict)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                }
                ForEach(profile.verdictReasons, id: \.self) { r in
                    Text(r).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: String(localized: "候选后端"))
                VStack(spacing: 0) {
                    ForEach(Array(profile.ladder.enumerated()), id: \.offset) { i, rung in
                        LadderRow(index: i, rung: rung, selected: engine.chosenRung(game.appid, in: profile) == rung) {
                            engine.choose(rung, for: game.appid)
                        }
                        if i < profile.ladder.count - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
                Text("点一项，作为这个游戏启动时使用的图形后端。默认用第一项。")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            if game.installKind == .wine { SteamLaunchToggle(game: game) }
            FactsTable(rows: Self.facts(game, profile))
            HStack {
                Spacer()
                Button("完成", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Theme.background)
    }

    static func facts(_ game: GameItem, _ p: GameProfile) -> [(String, String)] {
        let a = p.analysis
        var rows: [(String, String)] = [
            (String(localized: "图形"), a.likelyAPIs.map(Theme.apiLabel).joined(separator: "、").ifEmpty(String(localized: "未检测到"))),
            (String(localized: "架构"), Theme.machineLabel(a.mainMachine)),
            (String(localized: "引擎"), Theme.engineLabel(a.engine)),
            ("Steamworks", a.usesSteamworks ? String(localized: "后台 Windows Steam") : String(localized: "不使用")),
            (String(localized: "反作弊"), a.antiCheats.map(\.name).joined(separator: "、").ifEmpty(String(localized: "没有"))),
            (String(localized: "Valve 配置"), p.valveFlags.joined(separator: ", ").ifEmpty(String(localized: "无"))),
            (String(localized: "程序"), a.mainExecutable?.lastPathComponent ?? String(localized: "未知")),
        ]
        if let dir = game.installDir { rows.append((String(localized: "位置"), dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
        return rows
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

struct FactsTable: View {
    let rows: [(String, String)]
    var labelWidth: CGFloat = 84
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).foregroundStyle(Theme.secondary).frame(width: labelWidth, alignment: .leading)
                    Text(row.1).foregroundStyle(Theme.text).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.vertical, 8)
                if i < rows.count - 1 { Divider().overlay(Theme.hairline) }
            }
        }
    }
}

struct LadderRow: View {
    let index: Int
    let rung: LadderRung
    var selected = false
    var choose: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14, alignment: .trailing)
                Text(Theme.rendererLabel(rung.renderer))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: 150, alignment: .leading)
                Text(Theme.reasonLabel(rung.reason) + (rung.arguments.isEmpty ? "" : String(localized: "，参数 \(rung.arguments.joined(separator: " "))"))
                     + (rung.experimental ? String(localized: "（实验性）") : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(index + 1)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? Color.white.opacity(0.03) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension Theme {
    /// A step above the page background, like Steam's play bar strip.
    static let playBar = Color(red: 0.086, green: 0.086, blue: 0.094)
}
