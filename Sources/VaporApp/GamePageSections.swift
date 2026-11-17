import SwiftUI
import VaporKit

/// The part of Steam's game page below the achievements' header: play stats, web links, DLC and
/// the developer line. Every block renders only when Steam gave data for it.
struct GamePageSections: View {
    let appid: UInt32
    /// Opens a Steam web page inside Vapor's store tab.
    var open: (URL) -> Void = { _ in }
    var openProperties: () -> Void = {}

    @EnvironmentObject var engine: EngineModel
    @State private var details: SteamUI.AppDetails?
    @State private var achievementCount: (done: Int, total: Int)?
    @State private var dlcExpanded = false

    private static let collapsedDLC = 5
    private func t(_ key: String, _ fallback: String) -> String { engine.strings(key) ?? fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if !stats.isEmpty { statsStrip }
            links
            if let d = details, !d.dlc.isEmpty { dlcList(d.dlc) }
            if let line = creditLine { Text(line).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
        .task(id: engine.uiOnline ? appid : nil) { await load() }
        .task(id: engine.uiOnline ? appid : nil) { await engine.loadCloudState(appid) }
    }

    // MARK: stats

    private var stats: [(label: String, value: String)] {
        let app = engine.steamApps[appid]
        var out: [(String, String)] = []
        let minutes = max(app?.minutesPlayed ?? 0, details?.playtimeMinutes ?? 0)
        if minutes > 0 { out.append((t("AppDetails_SectionTitle_PlayTime", "游戏时间"), String(format: "%.1f 小时", Double(minutes) / 60))) }
        let last = max(app?.lastPlayed ?? 0, details?.lastPlayed ?? 0)
        if last > 0 { out.append((t("AppDetails_SectionTitle_LastPlayed", "最后运行日期"), Self.relative(Date(timeIntervalSince1970: TimeInterval(last))))) }
        if let a = achievementCount, a.total > 0 { out.append((t("AppDetails_SectionTitle_Achievements", "成就"), "\(a.done) / \(a.total)")) }
        if let d = details, d.cloudAvailable, d.cloudEnabledForAccount {
            // Steam's live sync status once read (已是最新, 正在上传…), else just whether it is on.
            let live = engine.cloudStates[appid].flatMap { $0.inUse ? engine.cloudLabel($0) : nil }
            let state = d.cloudEnabled ? live ?? "已启用" : t("AppDetails_CloudStatus_Disabled", "已禁用")
            out.append((t("AppDetails_SectionTitle_CloudStatus", "云存储状态"), d.cloudEnabled && !d.cloudUsed.isEmpty && !d.cloudUsed.hasPrefix("0 ") ? "\(state) · 已用 \(d.cloudUsed)" : state))
        }
        return out
    }

    private var statsStrip: some View {
        HStack(alignment: .top, spacing: 40) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: s.label)
                    Text(s.value).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 今天 / 昨天 / n 天前 within a week, the date after that.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2...6: return "\(days) 天前"
        default: return date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
        }
    }

    // MARK: links

    private var linkItems: [(title: String, path: String)] {
        let s = "https://store.steampowered.com", c = "https://steamcommunity.com/app/\(appid)"
        return [(t("AppDetails_Links_Store", "商店页面"), "\(s)/app/\(appid)/"),
                (t("AppDetails_Links_Community", "社区中心"), c),
                (t("AppDetails_Link_Discussions", "讨论区"), "\(c)/discussions/"),
                (t("AppDetails_Link_Guides", "指南"), "\(c)/guides/"),
                ("新闻", "\(s)/news/app/\(appid)"),
                (t("AppDetails_Links_PointsShop", "点数商店"), "\(s)/points/shop/app/\(appid)")]
            + (details?.workshopVisible == true ? [(t("AppProperties_WorkshopPage", "创意工坊"), "\(c)/workshop/")] : [])
    }

    private var links: some View {
        HStack(spacing: 0) {
            ForEach(Array(linkItems.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(width: 1, height: 12).padding(.horizontal, 14) }
                LinkButton(title: item.title) { if let url = URL(string: item.path) { open(url) } }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: DLC

    private func dlcList(_ all: [SteamUI.AppDetails.DLC]) -> some View {
        let rows = dlcExpanded ? all[...] : all.prefix(Self.collapsedDLC)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "\(t("AppDetails_SectionTitle_DLC", "DLC")) · \(all.count)")
                Spacer(minLength: 12)
                LinkButton(title: "管理", action: openProperties)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, x in
                    HStack(spacing: 12) {
                        Text(x.name.isEmpty ? "DLC \(x.id)" : x.name)
                            .font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 16)
                        if x.size > 0 { Text(bytes(x.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary) }
                        Text(Self.isInstalled(x) ? "已安装" : "未安装")
                            .font(.system(size: 12)).foregroundStyle(Self.isInstalled(x) ? Theme.secondary : Theme.tertiary)
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                    .padding(.vertical, 9)
                    if i < rows.count - 1 { Divider().overlay(Theme.hairline) }
                }
            }
            if all.count > Self.collapsedDLC {
                LinkButton(title: dlcExpanded ? "收起" : "显示全部 (\(all.count))") { dlcExpanded.toggle() }
            }
        }
    }

    /// Steam's strState is free text; read it for "installed" and fall back to the size on disk.
    private static func isInstalled(_ x: SteamUI.AppDetails.DLC) -> Bool {
        let s = x.state.lowercased()
        if s.contains("未") || s.contains("not") || s.contains("un") { return false }
        return s.contains("install") || s.contains("已") || x.size > 0
    }

    // MARK: credits

    private var creditLine: String? {
        guard let d = details, !d.developer.isEmpty else { return nil }
        return "\(t("AppDetails_Developer", "开发者："))\(d.developer)"
    }

    // MARK: loading

    private func load() async {
        details = nil
        achievementCount = nil
        dlcExpanded = false
        guard engine.uiOnline else { return }
        let engine = engine, ui = engine.ui, appid = appid
        async let count: Void = loadAchievementCount(ui, appid)
        // Steam can leave these calls hanging, so each races a timer.
        let (race, finish) = AsyncStream.makeStream(of: SteamUI.AppDetails?.self)
        let fetch = Task { finish.yield(await engine.details(appid)) }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            finish.yield(nil)
        }
        defer { timer.cancel(); fetch.cancel() }
        var result: SteamUI.AppDetails?
        for await r in race { result = r; break }
        if !Task.isCancelled { details = result }
        await count
    }

    private func loadAchievementCount(_ ui: SteamUI, _ appid: UInt32) async {
        let (race, finish) = AsyncStream.makeStream(of: [SteamUI.Achievement]?.self)
        let fetch = Task { finish.yield(try? await ui.achievements(appid)) }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            finish.yield(nil)
        }
        defer { timer.cancel(); fetch.cancel() }
        var result: [SteamUI.Achievement]?
        for await r in race { result = r; break }
        guard !Task.isCancelled, let result, !result.isEmpty else { return }
        achievementCount = (result.filter(\.achieved).count, result.count)
    }
}

/// Plain text button, secondary until hovered.
private struct LinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
