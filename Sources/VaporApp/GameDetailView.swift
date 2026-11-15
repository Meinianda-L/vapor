import SwiftUI
import VaporKit

struct GameDetailView: View {
    let game: GameItem
    let installs: [SteamInstall]
    var onBack: () -> Void = {}
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView { content }
            .overlay(alignment: .topLeading) { BackButton(action: onBack).padding(.top, 44).padding(.leading, 28) }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hero(game: game, installs: installs)
            VStack(alignment: .leading, spacing: 40) {
                GamePageSections(appid: game.appid, open: app.open, openProperties: { app.properties = game.appid })
                NewsSection(appid: game.appid) { app.show(.news(game.appid)) }
                DetailBody(game: game)
                AchievementsSection(appid: game.appid)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Hero: View {
    let game: GameItem
    let installs: [SteamInstall]

    private var meta: [String] {
        guard let p = game.profile else { return [game.hasMacBuild ? "Mac 原生" : "Windows", "AppID \(game.appid)"] }
        return ["Windows",
                Theme.machineLabel(p.analysis.mainMachine),
                p.analysis.likelyAPIs.first.map(Theme.apiLabel) ?? "",
                p.analysis.engine == .unknown ? "" : Theme.engineLabel(p.analysis.engine),
                "AppID \(game.appid)"]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Fixed-size box with the image as an overlay, so .fill never widens the page.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .overlay { ArtworkView(appid: game.appid, kind: .hero, installs: installs).scaledToFill() }
                .clipped()
                .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                                .init(color: Theme.background.opacity(0.85), location: 0.82),
                                                .init(color: Theme.background, location: 1)],
                                        startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    ArtworkView(appid: game.appid, kind: .logo, installs: installs)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 96, alignment: .bottomLeading)
                    MetaLine(parts: meta, size: 12.5)
                }
                Spacer(minLength: 24)
                ActionArea(game: game)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 22)
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
        .help("返回")
    }
}

/// Play, install, or download progress, depending on the game's state.
struct ActionArea: View {
    let game: GameItem
    @EnvironmentObject var engine: EngineModel
    @State private var sheet: GameSheet?
    @State private var confirmNativeLaunch = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let p = engine.progress[game.appid], !p.isInstalled {
                HStack(alignment: .bottom, spacing: 14) {
                    if engine.steamApps[game.appid] != nil { ManageMenu(game: game, sheet: $sheet) }
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(p.total > 0 ? "下载中 \(Int(p.fraction * 100))% · \(bytes(p.downloaded)) / \(bytes(p.total))" : "排队中，等待 Steam 开始下载")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text)
                        ProgressBar(fraction: p.fraction).frame(width: 220)
                    }
                }
            } else if game.installed && game.installKind == .wine {
                HStack(spacing: 10) {
                    ManageMenu(game: game, sheet: $sheet)
                    if engine.running.contains(game.appid) {
                        StopButton(title: engine.strings("GameAction_Stop") ?? "停止") { engine.stopGame(game.appid) }
                    } else {
                        PlayButton(enabled: game.profile != nil && game.verdict != .blocked && !engine.busy, installed: true,
                                   title: engine.busy && engine.lastLaunch == game.name ? "启动中…" : (engine.strings("GameAction_Play") ?? "开始游戏")) { engine.play(game) }
                    }
                }
            } else if game.installed && !game.windowsOnly {
                // Mac Steam runs its own installs; signing it in takes the account from Windows Steam.
                PlayButton(enabled: true, installed: true) {
                    if engine.isOnline { confirmNativeLaunch = true } else { launchInMacSteam() }
                }
            } else if game.installed {
                // Vapor runs games from Windows Steam's own install, which also keeps Steamworks working.
                Text("已在 Mac 版 Steam 中安装").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                PlayButton(enabled: engine.steam != nil && !engine.busy, installed: false, title: "在 Windows Steam 中安装") {
                    sheet = .install
                }
            } else if game.windowsOnly || !game.hasMacBuild {
                if engine.steamApps[game.appid] != nil { ManageMenu(game: game, sheet: $sheet) }
                PlayButton(enabled: engine.steam != nil && !engine.busy, installed: false, title: "安装") { sheet = .install }
            } else {
                Text("Mac 原生游戏，在 Mac 版 Steam 中安装").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .gameSheets(game, $sheet)
        .confirmationDialog("在 Mac 版 Steam 中启动 \(game.name)？", isPresented: $confirmNativeLaunch) {
            Button("启动") { launchInMacSteam() }
        } message: { Text("Mac 版 Steam 会登录同一账号，Windows Steam 随之下线，后台下载暂停。") }
    }

    private func launchInMacSteam() {
        NSWorkspace.shared.open(URL(string: "steam://rungameid/\(game.appid)")!)
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
                Capsule().fill(Theme.surface)
                Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

struct PlayButton: View {
    let enabled: Bool
    let installed: Bool
    var title: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: installed ? "play.fill" : "arrow.down.to.line").font(.system(size: 12, weight: .bold))
                Text(title ?? (installed ? "开始游戏" : "未安装")).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 22)
            .frame(height: 38)
            .foregroundStyle(enabled ? Color.black.opacity(0.88) : Theme.secondary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(enabled ? Theme.accent.opacity(hovering ? 0.88 : 1) : Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Steam's button while a game runs: same size as 开始游戏, quieter colour.
struct StopButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 22)
            .frame(height: 38)
            .foregroundStyle(Theme.text)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovering ? 0.16 : 0.11)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Two columns: how Vapor will run it (left), the facts (right).
struct DetailBody: View {
    let game: GameItem
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        if let p = game.profile {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 28) {
                    summary(p)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "候选后端")
                        VStack(spacing: 0) {
                            ForEach(Array(p.ladder.enumerated()), id: \.offset) { i, rung in
                                LadderRow(index: i, rung: rung, selected: engine.chosenRung(game.appid, in: p) == rung) {
                                    engine.choose(rung, for: game.appid)
                                }
                                if i < p.ladder.count - 1 { Divider().overlay(Theme.hairline) }
                            }
                        }
                        Text("点一项，作为这个游戏启动时使用的图形后端。默认用第一项。")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FactsTable(rows: facts(p))
                    .frame(width: 330)
            }
        } else {
            Text(game.installed ? "Mac 原生游戏，由 Steam 直接运行。" : "安装后，Vapor 会分析它用到的图形 API、反作弊和 Steamworks。")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }

    private func summary(_ p: GameProfile) -> some View {
        let first = p.ladder.first
        let exe = first?.executable.map { ($0 as NSString).lastPathComponent } ?? p.analysis.mainExecutable?.lastPathComponent ?? "游戏"
        let line: String = {
            guard p.verdict != .blocked else { return "这款游戏无法在 Vapor 中运行。" }
            var s = "用 \(first.map { Theme.rendererLabel($0.renderer) } ?? "WineD3D") 运行 \(exe)"
            if p.analysis.usesSteamworks { s += "，Steam 功能由后台的 Windows Steam 提供" }
            return s + "。"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(color: Theme.verdictColor(p.verdict))
                Text(Theme.verdictLabel(p.verdict)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(line)
                .font(.system(size: 20, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(p.verdictReasons, id: \.self) { r in
                Text(r).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func facts(_ p: GameProfile) -> [(String, String)] {
        let a = p.analysis
        var rows: [(String, String)] = [
            ("图形", a.likelyAPIs.map(Theme.apiLabel).joined(separator: "、").ifEmpty("未检测到")),
            ("架构", Theme.machineLabel(a.mainMachine)),
            ("引擎", Theme.engineLabel(a.engine)),
            ("Steamworks", a.usesSteamworks ? "后台 Windows Steam" : "不使用"),
            ("反作弊", a.antiCheats.map(\.name).joined(separator: "、").ifEmpty("没有")),
            ("Valve 配置", p.valveFlags.joined(separator: ", ").ifEmpty("无")),
            ("程序", a.mainExecutable?.lastPathComponent ?? "未知"),
        ]
        if let dir = game.installDir { rows.append(("位置", dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
        return rows
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

struct FactsTable: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).foregroundStyle(Theme.secondary).frame(width: 84, alignment: .leading)
                    Text(row.1).foregroundStyle(Theme.text).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.vertical, 9)
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
                Text(Theme.reasonLabel(rung.reason) + (rung.arguments.isEmpty ? "" : "，参数 \(rung.arguments.joined(separator: " "))")
                     + (rung.experimental ? "（实验性）" : ""))
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

/// The gear on a game page: the same menu as a right-click in the library.
struct ManageMenu: View {
    let game: GameItem
    @Binding var sheet: GameSheet?

    var body: some View {
        Menu {
            GameMenu(game: game, sheet: $sheet)
        } label: {
            Image(systemName: "gearshape").font(.system(size: 14))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("管理")
    }
}
