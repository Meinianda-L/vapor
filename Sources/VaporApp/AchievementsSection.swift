import SwiftUI
import VaporKit

/// The achievements block of Steam's game page: progress, then unlocked (newest first) and locked
/// (rarest last) rows. Renders nothing while loading, offline, or for games without achievements.
struct AchievementsSection: View {
    let appid: UInt32
    @EnvironmentObject var engine: EngineModel
    @State private var items: [SteamUI.Achievement] = []
    @State private var failed = false
    @State private var expanded = false
    @State private var unlocked = 0

    private static let collapsedCount = 6
    private var visible: ArraySlice<SteamUI.Achievement> { expanded ? items[...] : items.prefix(Self.collapsedCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: engine.strings("AppDetails_SectionTitle_Achievements") ?? String(localized: "成就"))
                        Spacer(minLength: 12)
                        Text("已解锁 \(unlocked) / \(items.count)")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    ProgressBar(fraction: Double(unlocked) / Double(items.count))
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { i, a in
                            AchievementRow(achievement: a)
                            if i < visible.count - 1 { Divider().overlay(Theme.hairline) }
                        }
                    }
                    if items.count > Self.collapsedCount {
                        Button(expanded ? "收起" : String(localized: "显示全部 (\(items.count))")) { expanded.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } else if failed {
                Text(engine.strings("Achievements_FailedToLoad_Title") ?? String(localized: "载入成就数据失败"))
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
        }
        .task(id: engine.uiOnline ? appid : nil) { await load() }
    }

    private func load() async {
        items = []
        failed = false
        expanded = false
        unlocked = 0
        guard engine.uiOnline else { return }
        let ui = engine.ui, appid = appid
        // Steam's call can run for 45 s and ignores cancellation, so race it against a shorter timer.
        let (race, finish) = AsyncStream.makeStream(of: [SteamUI.Achievement]?.self)
        let fetch = Task { finish.yield(try? await ui.achievements(appid)) }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            finish.yield(nil)
        }
        defer { timer.cancel(); fetch.cancel() }
        var result: [SteamUI.Achievement]?
        for await r in race { result = r; break }
        guard !Task.isCancelled else { return }
        guard let result else { failed = true; return }
        let done = result.filter(\.achieved).sorted { $0.unlockTime > $1.unlockTime }
        let todo = result.filter { !$0.achieved }       // Steam's own order; the client gives no global unlock rate
        unlocked = done.count
        items = done + todo
    }
}

private struct AchievementRow: View {
    let achievement: SteamUI.Achievement
    @EnvironmentObject var engine: EngineModel

    private var concealed: Bool { achievement.hidden && !achievement.achieved }

    private var unlockLine: String? {
        guard achievement.achieved, achievement.unlockTime > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(achievement.unlockTime))
            .formatted(.dateTime.year().month().day().locale(AppLanguage.locale))
        return engine.strings("AppDetails_Achievements_Unlocked", date) ?? String(localized: "解锁于 \(date)")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AchievementIcon(url: concealed ? nil : achievement.icon, locked: !achievement.achieved)
            VStack(alignment: .leading, spacing: 3) {
                Text(concealed ? String(localized: "隐藏成就") : achievement.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(achievement.achieved ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                if !concealed && !achievement.description.isEmpty {
                    Text(achievement.description)
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let line = unlockLine {
                    Text(line).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 16)
        }
        .padding(.vertical, 10)
    }
}

struct AchievementIcon: View {
    let url: URL?
    let locked: Bool
    var size: CGFloat = 48
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.surface)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .saturation(locked ? 0 : 1).opacity(locked ? 0.5 : 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .task(id: url) {
                guard let url else { return }
                image = await AchievementIcons.image(url)
            }
    }
}

/// Icons come from Steam's CDN (slow from China), so each is fetched once per session.
private enum AchievementIcons {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}
