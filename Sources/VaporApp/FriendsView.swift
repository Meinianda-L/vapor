import SwiftUI
import VaporKit

/// Steam's friends list, rebuilt natively: playing, online, offline, read from the client's friendStore
/// through SteamUI.
struct FriendsView: View {
    @EnvironmentObject var engine: EngineModel
    /// Called with the friend's steamID64 from a row's profile action.
    var openProfile: (String) -> Void = { _ in }

    init(openProfile: @escaping (String) -> Void = { _ in }, chatWith: String? = nil) {
        self.openProfile = openProfile
        _chatID = State(initialValue: chatWith)
    }

    @State private var friends: [SteamUI.Friend]?
    @State private var failed = false
    @State private var query = ""
    @State private var showOffline = false
    @State private var chatID: String?

    /// Offline friends beyond this many stay folded into a count until asked for.
    private static let offlineLimit = 8

    private struct Groups {
        var matchCount = 0
        var playing: [SteamUI.Friend] = []
        var online: [SteamUI.Friend] = []
        var offline: [SteamUI.Friend] = []
    }

    /// One pass over the list per render: filter, group, then sort each group once.
    private func grouped(unread: [String: Int]) -> Groups {
        let q = query.trimmingCharacters(in: .whitespaces)
        var g = Groups()
        for f in friends ?? [] where !f.steamID.isEmpty {
            if !q.isEmpty && !f.name.localizedCaseInsensitiveContains(q) { continue }
            g.matchCount += 1
            if !f.shownOnline { g.offline.append(f) }
            else if f.gameAppID != 0 { g.playing.append(f) }
            else { g.online.append(f) }
        }
        g.playing = unreadFirst(sorted(g.playing), unread)
        g.online = unreadFirst(sorted(g.online), unread)
        g.offline.sort { $0.lastOnline > $1.lastOnline }
        g.offline = unreadFirst(g.offline, unread)
        return g
    }

    /// Stable: friends with waiting messages move up, everyone keeps their relative order.
    private func unreadFirst(_ list: [SteamUI.Friend], _ unread: [String: Int]) -> [SteamUI.Friend] {
        list.filter { unread[$0.steamID, default: 0] > 0 } + list.filter { unread[$0.steamID, default: 0] == 0 }
    }

    private func sorted(_ list: [SteamUI.Friend]) -> [SteamUI.Friend] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func t(_ key: String, _ fallback: String, _ args: String...) -> String {
        guard var s = engine.strings(key) else { return fallback }
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$s", with: a) }
        return s
    }

    private var chatFriend: SteamUI.Friend? {
        guard let chatID else { return nil }
        return friends?.first { $0.steamID == chatID }
    }

    var body: some View {
        let chat = chatFriend
        HStack(spacing: 0) {
            list(narrow: chat != nil)
                .frame(width: chat == nil ? nil : 360)
            if let chat {
                Divider().overlay(Theme.hairline)
                ChatView(friend: chat) { chatID = nil }
            }
        }
    }

    private func list(narrow: Bool) -> some View {
        var unread: [String: Int] = [:]
        for c in engine.chats { unread[c.steamID, default: 0] += c.unread }
        let g = grouped(unread: unread)
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !engine.uiOnline {
                    note(engine.isOnline ? "正在读取…" : "Windows Steam 未运行")
                } else if friends == nil {
                    note(failed ? "读取好友列表失败，稍后重试" : "正在读取…")
                } else if friends?.isEmpty == true {
                    note("好友列表为空")
                } else if g.matchCount == 0 {
                    note("没有匹配的好友")
                } else {
                    section(t("Settings_Page_InGame", "游戏中"), g.playing, unread)
                    section(t("Menu_Status_Online", "在线"), g.online, unread)
                    offlineSection(g.offline, unread)
                }
            }
            .padding(.horizontal, narrow ? 20 : 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyed on uiOnline so the first read happens the moment the client becomes reachable.
        .task(id: engine.uiOnline) {
            // A new Steam session starts from "reading", not from the last one's list.
            friends = nil
            failed = false
            guard engine.uiOnline else { return }
            var emptyReads = 0
            while !Task.isCancelled {
                var delay = 10.0
                do {
                    let list = try await engine.ui.friends()
                    guard !Task.isCancelled else { return }
                    failed = false
                    // The client may not have populated its friend store yet: an empty first
                    // answer is retried quickly a few times before it is believed.
                    if list.isEmpty && friends == nil && emptyReads < 3 {
                        emptyReads += 1
                        delay = 2
                    } else if list != friends {
                        friends = list
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if friends == nil { failed = true }
                    delay = friends == nil ? 3 : 10
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t("Menu_Friends", "好友")).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            if engine.uiOnline && friends?.isEmpty == false { SearchField(text: $query) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SteamUI.Friend], _ unread: [String: Int], trailing: AnyView? = nil) -> some View {
        if !items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "\(title)（\(items.count)）")
                    Spacer()
                    trailing
                }
                .padding(.bottom, 8)
                ForEach(items) { friend in
                    FriendRow(friend: friend, unread: unread[friend.steamID, default: 0],
                              selected: friend.steamID == chatID,
                              chat: { chatID = friend.steamID }, profile: openProfile)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    @ViewBuilder
    private func offlineSection(_ items: [SteamUI.Friend], _ unread: [String: Int]) -> some View {
        // A search is looking for someone, so it never hides the matches.
        let folded = items.count > Self.offlineLimit && !showOffline && query.isEmpty
        if folded {
            HStack {
                SectionLabel(text: "\(t("Menu_Status_Offline", "离线"))（\(items.count)）")
                Spacer()
                toggle("显示")
            }
        } else {
            section(t("Menu_Status_Offline", "离线"), items, unread,
                    trailing: items.count > Self.offlineLimit && query.isEmpty ? AnyView(toggle("隐藏")) : nil)
        }
    }

    private func toggle(_ title: String) -> some View {
        Button(title) { showOffline.toggle() }
            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
    }
}

extension SteamUI.Friend {
    /// Invisible (7) friends are shown as offline; a stale game on an offline persona is ignored.
    var shownOnline: Bool { state != 0 && state != 7 }

    /// "在线 · Game" / "离线 · 上次在线 …", shared by the list rows and the chat header.
    @MainActor
    func statusLine(_ engine: EngineModel) -> String {
        var line = personaLabel(engine)
        if shownOnline, gameAppID != 0 {
            line += "  ·  " + (engine.steamApps[gameAppID]?.name ?? (gameName.isEmpty ? "App \(gameAppID)" : gameName))
        } else if !shownOnline, lastOnline > 0 {
            line += "  ·  " + Self.lastSeen(lastOnline)
        }
        return line
    }

    // EPersonaState. Steam's localization has no entries for busy, trade, play or invisible.
    @MainActor
    func personaLabel(_ engine: EngineModel) -> String {
        switch state {
        case 0: return engine.strings("Menu_Status_Offline") ?? "离线"
        case 1: return engine.strings("Menu_Status_Online") ?? "在线"
        case 2: return "忙碌"
        case 7: return "隐身"
        case 3, 4: return engine.strings("Menu_Status_Away") ?? "离开"
        case 5: return "想交易"
        case 6: return "想玩游戏"
        default: return engine.strings("Menu_Status_Online") ?? "在线"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        return f
    }()

    static func lastSeen(_ time: Int) -> String {
        let seen = Date(timeIntervalSince1970: TimeInterval(time))
        return "上次在线 \(relative.localizedString(for: seen, relativeTo: Date()))"
    }
}

private struct FriendRow: View {
    @EnvironmentObject var engine: EngineModel
    let friend: SteamUI.Friend
    let unread: Int
    let selected: Bool
    let chat: () -> Void
    let profile: (String) -> Void
    @State private var hovering = false

    private var game: String? {
        guard friend.shownOnline, friend.gameAppID != 0 else { return nil }
        if let name = engine.steamApps[friend.gameAppID]?.name { return name }
        return friend.gameName.isEmpty ? "App \(friend.gameAppID)" : friend.gameName
    }

    private var lastSeen: String? {
        guard !friend.shownOnline, friend.lastOnline > 0 else { return nil }
        return SteamUI.Friend.lastSeen(friend.lastOnline)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: chat) {
                HStack(spacing: 12) {
                    Avatar(url: friend.avatar, name: friend.name)
                        .opacity(friend.shownOnline ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(friend.name.isEmpty ? friend.steamID : friend.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(friend.shownOnline ? Theme.text : Theme.secondary)
                            .lineLimit(1)
                        HStack(spacing: 0) {
                            Text(friend.personaLabel(engine)).foregroundStyle(Theme.secondary)
                            if let game {
                                Text("  ·  ").foregroundStyle(Theme.tertiary)
                                Text(game).foregroundStyle(Theme.ok)
                            } else if let lastSeen {
                                Text("  ·  ").foregroundStyle(Theme.tertiary)
                                Text(lastSeen).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .font(.system(size: 11.5)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering {
                Button("资料") { profile(friend.steamID) }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(Theme.accent))
            }
        }
        .padding(.vertical, 8)
        .background(selected || hovering ? Theme.surface : .clear)
        .onHover { hovering = $0 }
        .contextMenu { Button("查看个人资料") { profile(friend.steamID) } }
    }
}

struct Avatar: View {
    let url: URL?
    let name: String
    @State private var image: NSImage?

    init(url: URL?, name: String) {
        self.url = url
        self.name = name
        _image = State(initialValue: url.flatMap { AvatarCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.surface
                Text(String(name.first ?? "?").uppercased())
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .task(id: url) {
            // The address changes when a friend changes their picture; rows keep their identity.
            guard let url else { image = nil; return }
            image = AvatarCache.shared.cached(url)
            guard image == nil else { return }
            for attempt in 0..<3 {
                if let img = await AvatarCache.shared.load(url) { image = img; return }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 5))
            }
        }
    }
}

/// Avatars are small and change rarely; each address is fetched once per run, off the main thread.
@MainActor
private final class AvatarCache {
    static let shared = AvatarCache()
    private let images = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    /// Concurrent requests for one address share a single fetch; failures are not cached.
    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task { () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let img = await task.value
        inFlight[url] = nil
        if let img { images.setObject(img, forKey: url as NSURL) }
        return img
    }
}
