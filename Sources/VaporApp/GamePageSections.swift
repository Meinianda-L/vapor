import SwiftUI
import VaporKit

/// Formatting shared by the app page's parts, in Steam's own words.
enum GamePage {
    /// EDisplayStatus k_EDisplayStatusUpdateRequired.
    static let updateRequired = 20

    /// 今天 / 昨天 / n 天前 within a week, the date after that.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return String(localized: "今天")
        case 1: return String(localized: "昨天")
        case 2...6: return String(localized: "\(days) 天前")
        default: return date.formatted(.dateTime.year().month().day().locale(AppLanguage.locale))
        }
    }

    /// Steam's playtime: minutes under an hour, hours with one decimal after that.
    static func playtime(_ minutes: Int, _ strings: SteamStrings) -> String {
        if minutes < 60 { return strings("Playtime_Minutes", "\(minutes)") ?? String(localized: "\(minutes) 分钟") }
        let hours = String(format: "%.1f", Double(minutes) / 60)
        return strings("Playtime_Hours", hours) ?? String(localized: "\(hours) 小时")
    }

    /// The play bar's 云状态 value for steamui's ECloudStatus.
    static func cloudStatus(_ code: Int, progress: Int, _ strings: SteamStrings) -> String {
        let key: String
        switch code {
        case 1: key = "Disabled"
        case 3: key = "Synchronized"
        case 4: key = "Checking"
        case 5: key = "OutOfSync"
        case 6: return progress > 0 ? strings("AppDetails_CloudStatus_UploadingPercent", "\(progress)") ?? String(localized: "正在上传…") : strings("AppDetails_CloudStatus_Uploading") ?? String(localized: "正在上传…")
        case 7: return progress > 0 ? strings("AppDetails_CloudStatus_DownloadingPercent", "\(progress)") ?? String(localized: "正在下载…") : strings("AppDetails_CloudStatus_Downloading") ?? String(localized: "正在下载…")
        case 8: key = "SyncFailed"
        case 9: key = "Conflict"
        case 10: key = "PendingElsewhere"
        default: key = "Unknown"
        }
        return strings("AppDetails_CloudStatus_\(key)") ?? String(localized: "未知")
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(AppLanguage.locale))
    }
}

// MARK: - Link strip

/// 商店页面 · DLC · 社区中心 · 讨论区 · 指南 · 客服 · …, every link through AppState.open.
struct LinkStrip: View {
    let appid: UInt32
    let content: GamePageModel.Content
    let open: (URL) -> Void
    @EnvironmentObject var engine: EngineModel

    private func t(_ key: String, _ fallback: String) -> String { engine.strings(key) ?? fallback }
    private var store: String { "https://store.steampowered.com" }
    private var community: String { "https://steamcommunity.com/app/\(appid)" }

    private var main: [(String, String)] {
        let hasDLC = !(content.details?.dlc.isEmpty ?? true) || !(content.store?.dlc.isEmpty ?? true)
        return [(t("AppDetails_Links_Store", String(localized: "商店页面")), "\(store)/app/\(appid)/")]
            + (hasDLC ? [(t("AppDetails_Links_DLC", "DLC"), "\(store)/dlc/\(appid)/")] : [])
            + [(t("AppDetails_Links_Community", String(localized: "社区中心")), community),
               (t("AppDetails_Link_Discussions", String(localized: "讨论区")), "\(community)/discussions/"),
               (t("AppDetails_Link_Guides", String(localized: "指南")), "\(community)/guides/"),
               (t("AppDetails_Link_Support", String(localized: "客服")), "https://help.steampowered.com/zh-cn/wizard/HelpWithGame/?appid=\(appid)")]
    }

    private var more: [(String, String)] {
        var out = [(t("AppDetails_Links_PointsShop", String(localized: "点数商店")), "\(store)/points/shop/app/\(appid)")]
        if content.info?.workshopVisible == true { out.append((t("AppDetails_Link_Workshop", String(localized: "创意工坊")), "\(community)/workshop/")) }
        if content.info?.marketPresence == true { out.append((t("AppDetails_Link_Market", String(localized: "市场")), "https://steamcommunity.com/market/search?appid=\(appid)")) }
        out.append((t("AppDetails_ViewAllUpdates", String(localized: "查看所有更新")), "\(store)/news/app/\(appid)"))
        if let home = content.info?.homepage { out.append((String(localized: "网站"), home.absoluteString)) }
        if let manual = content.info?.manual { out.append((t("AppDetails_AdditionalContent_GameManual", String(localized: "手册")), manual.absoluteString)) }
        return out
    }

    var body: some View {
        HStack(spacing: 22) {
            ForEach(main, id: \.1) { item in
                LinkText(title: item.0) { if let url = URL(string: item.1) { open(url) } }
            }
            Menu {
                ForEach(more, id: \.1) { item in
                    Button(item.0) { if let url = URL(string: item.1) { open(url) } }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 18).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

/// Plain text button, secondary until hovered.
struct LinkText: View {
    let title: String
    var size: CGFloat = 12.5
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Info panel (ⓘ)

/// What the play bar's ⓘ opens: the store's short description and features, quietly set.
struct GameInfoPanel: View {
    let game: GameItem
    let content: GamePageModel.Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = content.store, !s.shortDescription.isEmpty {
                Text(s.shortDescription)
                    .font(.system(size: 13.5)).foregroundStyle(Theme.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
                let features = s.categories.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !features.isEmpty {
                    Text(features.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            } else {
                Text(content.store == nil ? String(localized: "正在载入…") : String(localized: "商店没有这款游戏的介绍。")).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
    }
}

// MARK: - Right column

/// The right column of Steam's app page: friends, achievements, cards, screenshots, notes, DLC, info,
/// plus Vapor's own compatibility card.
struct SideColumn: View {
    let game: GameItem
    let content: GamePageModel.Content
    let open: (URL) -> Void
    var reloadNotes: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            CompatibilityCard(game: game)
            if let f = content.friends, !f.isEmpty { FriendsCard(friends: f, appid: game.appid, software: content.info?.isSoftware ?? false, name: game.name, open: open) }
            if let a = content.achievements, !a.isEmpty { AchievementsCard(appid: game.appid, achievements: a) }
            if let b = content.badge { TradingCardsCard(appid: game.appid, badge: b, open: open) }
            if game.installed || !content.screenshots.isEmpty { ScreenshotsCard(shots: content.screenshots) }
            if let notes = content.notes { NotesCard(appid: game.appid, name: game.name, notes: notes, reload: reloadNotes) }
            if let d = content.details, !d.dlc.isEmpty { DLCCard(appid: game.appid, dlc: d.dlc) }
            GameInfoCard(content: content)
        }
    }
}

/// Section chrome: a small heading, an optional link at its right, the body below.
struct SideCard<Content: View>: View {
    let title: String
    var action: (title: String, run: () -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).kerning(0.3)
                Spacer(minLength: 8)
                if let action { LinkText(title: action.title, size: 11.5, action: action.run) }
            }
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: 6) }
            content()
        }
    }
}

private struct CompatibilityCard: View {
    let game: GameItem
    @EnvironmentObject var engine: EngineModel
    @State private var showLadder = false

    var body: some View {
        SideCard(title: String(localized: "Vapor 兼容性"), action: game.profile.map { _ in (String(localized: "更改…"), { showLadder = true }) }) {
            if let p = game.profile {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: Theme.verdictColor(p.verdict))
                        Text(Theme.verdictLabel(p.verdict)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                    }
                    let rung = engine.chosenRung(game.appid, in: p) ?? p.ladder.first
                    Text("图形后端：\(rung.map { Theme.rendererLabel($0.renderer) } ?? "WineD3D")")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if game.installKind == .wine && engine.steamLaunched.contains(game.appid) {
                        Text(engine.steamLaunchBlocker(game) == nil ? String(localized: "由 Steam 启动") : String(localized: "由 Vapor 启动（Steam 启动不适用此后端）"))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    }
                    if let reason = p.verdictReasons.first {
                        Text(reason).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(2)
                    }
                }
                .sheet(isPresented: $showLadder) { CompatibilitySheet(game: game, profile: p) { showLadder = false } }
            } else {
                Text(game.installed ? String(localized: "Mac 原生游戏，由 Steam 直接运行。") : String(localized: "安装后，Vapor 会分析它用到的图形 API、反作弊和 Steamworks。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FriendsCard: View {
    let friends: SteamUI.AppFriends
    let appid: UInt32
    let software: Bool
    let name: String
    let open: (URL) -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var expanded = false

    private func t(_ key: String, _ args: String...) -> String { engine.strings.text(key, args) ?? key }
    private func profile(_ f: SteamUI.AppFriend) { if let url = URL(string: "https://steamcommunity.com/profiles/\(f.steamID)") { open(url) } }

    var body: some View {
        SideCard(title: software ? t("AppDetails_SectionTitle_Friends_Software") : t("AppDetails_SectionTitle_Friends"),
                 action: (t("AppDetails_Friends_ViewAll"), { if let url = URL(string: "https://steamcommunity.com/my/friendsthatplay/\(appid)") { open(url) } })) {
            VStack(alignment: .leading, spacing: 16) {
                if !friends.inGame.isEmpty {
                    group(t("AppDetails_FriendsInGameNow", "\(friends.inGame.count)")) {
                        ForEach(friends.inGame) { f in row(f, detail: nil) }
                    }
                }
                if !friends.recent.isEmpty {
                    group(t("AppDetails_FriendsPlayedRecently", "\(friends.recent.count)")) {
                        ForEach(expanded ? friends.recent : Array(friends.recent.prefix(5))) { f in
                            row(f, detail: f.minutesRecent > 0 ? t("Playtime_Recently", GamePage.playtime(f.minutesRecent, engine.strings)) : nil)
                        }
                        if friends.recent.count > 5 && !expanded {
                            LinkText(title: t("AppDetails_FriendsPlayedRecentlyExpand"), size: 11.5) { expanded = true }
                        }
                    }
                }
                if !friends.ever.isEmpty { avatars(t("AppDetails_FriendsPlayed", "\(friends.ever.count)"), friends.ever) }
                if !friends.wishlist.isEmpty { avatars(t("AppDetails_FriendsWishlisted", "\(friends.wishlist.count)", name), friends.wishlist) }
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            body()
        }
    }

    private func row(_ f: SteamUI.AppFriend, detail: String?) -> some View {
        Button { profile(f) } label: {
            HStack(spacing: 10) {
                Avatar(url: f.avatar, name: f.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(f.state != 0 ? Theme.text : Theme.secondary).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func avatars(_ title: String, _ list: [SteamUI.AppFriend]) -> some View {
        let shown = Array(list.prefix(14))
        return group(title) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
                ForEach(shown) { f in
                    Button { profile(f) } label: { Avatar(url: f.avatar, name: f.name) }.buttonStyle(.plain).help(f.name)
                }
                if list.count > shown.count {
                    Text("+\(list.count - shown.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 34, height: 34).background(Circle().fill(Theme.surface))
                }
            }
        }
    }
}

private struct AchievementsCard: View {
    let appid: UInt32
    let achievements: [SteamUI.Achievement]
    @EnvironmentObject var engine: EngineModel
    @State private var showAll = false

    var body: some View {
        let done = achievements.filter(\.achieved).sorted { $0.unlockTime > $1.unlockTime }
        let locked = achievements.filter { !$0.achieved && !$0.hidden }
        let pct = Int((Double(done.count) / Double(achievements.count) * 100).rounded())
        let label = done.count == achievements.count
            ? engine.strings("AppDetails_PlayerUnlockedPercentAll", "\(done.count)", "\(achievements.count)") ?? String(localized: "您已解锁所有成就！")
            : engine.strings("AppDetails_PlayerUnlockedPercent", "\(done.count)", "\(achievements.count)") ?? String(localized: "您已解锁 \(done.count)/\(achievements.count)")
        SideCard(title: engine.strings("AppDetails_SectionTitle_Achievements") ?? String(localized: "成就"),
                 action: (engine.strings("AppDetails_ViewAllAchievements") ?? String(localized: "查看我的成就"), { showAll = true })) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(pct)%").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                ProgressBar(fraction: Double(done.count) / Double(achievements.count))
                if !done.isEmpty { icons(done, locked: false) }
                if !locked.isEmpty {
                    Text(engine.strings("AppDetails_Achievements_Locked") ?? String(localized: "锁定的成就")).font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.top, 2)
                    icons(locked, locked: true)
                }
            }
        }
        .sheet(isPresented: $showAll) {
            VStack(spacing: 0) {
                ScrollView { AchievementsSection(appid: appid).padding(24) }
                Divider().overlay(Theme.hairline)
                HStack { Spacer(); Button(engine.strings("Button_Close") ?? String(localized: "关闭")) { showAll = false }.keyboardShortcut(.cancelAction) }.padding(14)
            }
            .frame(width: 620, height: 640)
            .background(Theme.background)
        }
    }

    /// One row of icons; the last slot becomes "+N" when they do not fit, as in Steam.
    private func icons(_ list: [SteamUI.Achievement], locked: Bool) -> some View {
        let slots = 6
        let shown = list.count > slots ? Array(list.prefix(slots - 1)) : list
        return HStack(spacing: 6) {
            ForEach(shown) { a in
                AchievementIcon(url: a.icon, locked: locked, size: 40).help(a.name)
            }
            if list.count > shown.count {
                Text("+\(list.count - shown.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.secondary)
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.hairline))
            }
        }
    }
}

private struct TradingCardsCard: View {
    let appid: UInt32
    let badge: SteamUI.AppBadge
    let open: (URL) -> Void
    @EnvironmentObject var engine: EngineModel

    private func t(_ key: String, _ args: String...) -> String { engine.strings.text(key, args) ?? key }

    var body: some View {
        SideCard(title: t("AppDetails_SectionTitle_TradingCards"),
                 action: (t("AppDetails_ViewTradingCards"), { if let url = URL(string: "https://steamcommunity.com/my/gamecards/\(appid)/") { open(url) } })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let icon = badge.icon {
                        StoreImage(url: icon, corner: 0).frame(width: 40, height: 40).clipShape(Circle())
                    } else {
                        Circle().stroke(Theme.hairline, lineWidth: 1.5).frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(badge.level > 0 ? badge.name : badge.nextLevelName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(badge.level > 0 ? t("AppDetails_BadgeLevel", "\(badge.level)", "\(badge.xp)") : t("AppDetails_UnearnedBadgeXP", "\(badge.nextLevelXP)"))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(badge.cards) { card in
                        StoreImage(url: card.image, corner: 3)
                            .aspectRatio(224.0 / 261, contentMode: .fit)
                            .saturation(card.owned > 0 ? 1 : 0.1)
                            .opacity(card.owned > 0 ? 1 : 0.45)
                            .overlay(alignment: .bottomTrailing) {
                                if card.owned > 1 {
                                    Text("×\(card.owned)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 3).background(Color.black.opacity(0.6)).padding(2)
                                }
                            }
                            .help(card.title)
                    }
                }
            }
        }
    }

    private var status: String {
        if badge.maxed { return t("AppDetails_TradingCardsMaxed") }
        let left = badge.missing
        if left == 0 { return t("AppDetails_TradingCardsLevelUp") }
        return left == 1 ? t("AppDetails_TradingCardsLeft") : t("AppDetails_TradingCardsLeft_Plural", "\(left)")
    }
}

private struct ScreenshotsCard: View {
    let shots: [URL]
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        let manage = shots.isEmpty ? nil : (engine.strings("AppDetails_ManageMyScreenshots_Plural", "\(shots.count)") ?? String(localized: "管理我的截图"),
                                             { NSWorkspace.shared.activateFileViewerSelecting([shots[0]]) })
        SideCard(title: engine.strings("AppDetails_SectionTitle_Screenshots") ?? String(localized: "屏幕截图"), action: manage) {
            if shots.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.strings("AppDetails_NoScreenshots") ?? String(localized: "您还没有进行任何截图")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text(engine.strings("AppDetails_HowToScreenshot", "F12") ?? String(localized: "在游戏中按下 F12 可进行截图。")).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(shots.prefix(4), id: \.self) { url in
                        LocalThumb(url: url).aspectRatio(16.0 / 9, contentMode: .fit)
                            .onTapGesture { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }
}

/// A file on disk, decoded off the main thread.
private struct LocalThumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Rectangle().fill(Color(white: 0.12))
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .task(id: url) {
                let url = url
                image = await Task.detached { NSImage(contentsOf: url) }.value
            }
    }
}

private struct NotesCard: View {
    let appid: UInt32
    let name: String
    let notes: [SteamUI.AppNote]
    let reload: () -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var editing: NoteEditor.Target?

    var body: some View {
        SideCard(title: engine.strings("AppDetails_SectionTitle_GameNotes") ?? String(localized: "笔记"),
                 action: (engine.strings("AppDetails_NewNote") ?? String(localized: "新笔记"), { editing = .new })) {
            if notes.isEmpty {
                Text("还没有笔记。").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(notes.prefix(5)) { note in
                        LinkText(title: note.title.isEmpty ? (engine.strings("UserGameNotes_Untitled") ?? String(localized: "无标题")) : note.title, size: 12.5) {
                            editing = .note(note)
                        }
                        .lineLimit(1)
                    }
                    if notes.count > 5 { Text("还有 \(notes.count - 5) 条").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                }
            }
        }
        .sheet(item: $editing) { target in NoteEditor(appid: appid, name: name, target: target, saved: reload) { editing = nil } }
    }
}

private struct DLCCard: View {
    let appid: UInt32
    let dlc: [SteamUI.AppDetails.DLC]
    @EnvironmentObject var engine: EngineModel
    @EnvironmentObject var app: AppState
    @State private var expanded = false

    var body: some View {
        let rows = expanded ? dlc[...] : dlc.prefix(5)
        SideCard(title: engine.strings("AppDetails_SectionTitle_DLC") ?? "DLC",
                 action: (engine.strings("AppDetails_ManageDLC", "\(dlc.count)") ?? String(localized: "管理我的 DLC"), { app.properties = appid })) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, x in
                    HStack(spacing: 10) {
                        Text(x.name.isEmpty ? "DLC \(x.id)" : x.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.isInstalled(x) ? String(localized: "已安装") : String(localized: "未安装")).font(.system(size: 11))
                            .foregroundStyle(Self.isInstalled(x) ? Theme.secondary : Theme.tertiary)
                    }
                    .padding(.vertical, 7)
                    if i < rows.count - 1 { Divider().overlay(Theme.hairline) }
                }
                if dlc.count > 5 {
                    LinkText(title: expanded ? String(localized: "收起") : String(localized: "显示全部 (\(dlc.count))"), size: 11.5) { expanded.toggle() }.padding(.top, 6)
                }
            }
        }
    }

    /// Steam's strState is free text; read it for "installed" and fall back to the size on disk.
    static func isInstalled(_ x: SteamUI.AppDetails.DLC) -> Bool {
        let s = x.state.lowercased()
        if s.contains("未") || s.contains("not") || s.contains("un") { return false }
        return s.contains("install") || s.contains("已") || x.size > 0
    }
}

private struct GameInfoCard: View {
    let content: GamePageModel.Content
    @EnvironmentObject var engine: EngineModel

    private func t(_ key: String, _ fallback: String) -> String { (engine.strings(key) ?? fallback).trimmingCharacters(in: CharacterSet(charactersIn: "：: ")) }

    private var rows: [(String, String)] {
        let s = content.store
        var out: [(String, String)] = []
        let developer = s?.developers.joined(separator: "、").ifEmpty(content.info?.developer ?? "") ?? content.info?.developer ?? ""
        if !developer.isEmpty { out.append((t("AppDetails_Developer", String(localized: "开发者")), developer)) }
        if let p = s?.publishers, !p.isEmpty { out.append((t("AppDetails_Publisher", String(localized: "发行商")), p.joined(separator: "、"))) }
        if let release = content.info?.releaseDate { out.append((t("AppDetails_ReleaseDate", String(localized: "发行日期")), GamePage.date(release))) }
        else if let r = s?.releaseDate, !r.isEmpty { out.append((t("AppDetails_ReleaseDate", String(localized: "发行日期")), r)) }
        if let g = s?.genres, !g.isEmpty { out.append((String(localized: "类型"), g.joined(separator: "、"))) }
        if let d = content.details, d.installed, d.lastUpdated > 0 {
            out.append((t("AppDetails_LastUpdate", String(localized: "最后一次本地更新")), GamePage.date(Date(timeIntervalSince1970: TimeInterval(d.lastUpdated)))))
        }
        return out
    }

    var body: some View {
        if !rows.isEmpty {
            SideCard(title: engine.strings("AppDetails_GameInfo") ?? String(localized: "游戏信息")) {
                FactsTable(rows: rows, labelWidth: 96)
            }
        }
    }
}
