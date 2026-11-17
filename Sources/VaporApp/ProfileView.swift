import AppKit
import SwiftUI
import VaporKit

/// A Steam Community profile drawn natively: the public XML view of the profile plus, when the id is a
/// friend or the signed-in user, what Steam's client knows right now (state, game, last online).
struct ProfileView: View {
    @EnvironmentObject var engine: EngineModel
    let steamID: String
    var open: (URL) -> Void = { _ in }
    var openGame: (UInt32) -> Void = { _ in }
    var onClose: () -> Void = {}
    var openChat: ((String) -> Void)?
    var startEditing = false

    private enum Phase { case loading, loaded(ProfileData), failed }
    @State private var phase: Phase = .loading
    @State private var friend: SteamUI.Friend?
    @State private var editing = false

    private var isOwn: Bool { engine.account?.steamID == steamID }
    private var profileURL: URL? { URL(string: "https://steamcommunity.com/profiles/\(steamID)/") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button(action: onClose) {
                    Text("‹ 返回").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                switch phase {
                case .loading:
                    header(nil)
                    ProgressView().controlSize(.small)
                case .failed:
                    header(nil)
                    HStack(spacing: 12) {
                        Text("无法载入个人资料。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button("重试") { Task { await load(force: true) } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                case .loaded(let data):
                    header(data)
                    actions
                    if !data.isPublic {
                        Text("该个人资料是私密的").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    if let summary = data.summary {
                        Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                    if !data.games.isEmpty { gamesSection(data.games) }
                    if !data.groups.isEmpty { groupsSection(data.groups) }
                    if data.isPublic || isOwn { CommentsSection(thread: .profile(steamID), open: open) }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 52).padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .environment(\.openURL, OpenURLAction { url in open(url); return .handled })
        .task(id: steamID) { await load(force: false) }
        .sheet(isPresented: $editing) {
            ProfileEditSheet(steamID: steamID, saved: { Task { await load(force: true) } }, dismiss: { editing = false })
        }
        .onAppear { if startEditing && isOwn { editing = true } }
    }

    // MARK: header

    private func header(_ data: ProfileData?) -> some View {
        let name = friend?.name ?? (isOwn ? engine.account?.persona : nil) ?? data?.name ?? ""
        let avatar = data?.avatar ?? friend?.avatar ?? (isOwn ? engine.account?.avatar : nil)
        return HStack(alignment: .top, spacing: 22) {
            RemoteImage(url: avatar, width: 112, height: 112, radius: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(name.isEmpty ? " " : name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let status = status(data) {
                    HStack(spacing: 7) {
                        StatusDot(color: status.color)
                        Text(status.text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                if let data {
                    MetaLine(parts: [data.isPublic ? data.realName : "", data.isPublic ? data.location : "",
                                     data.memberSince.map { String(localized: "加入于 \($0)") } ?? ""], size: 12)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func status(_ data: ProfileData?) -> (text: String, color: Color)? {
        var state: Int?
        var game = ""
        if let friend {
            state = friend.state
            game = friend.gameName
        } else if isOwn, let account = engine.account {
            state = account.personaState
        } else if let data {
            switch data.onlineState {
            case "online": state = 1
            case "in-game": state = 1; game = data.stateMessage
            case "offline": state = 0
            default: state = nil
            }
        }
        guard let state else { return nil }
        if !game.isEmpty { return (String(localized: "正在游戏 · \(game)"), Theme.ok) }
        switch state {
        case 1, 5, 6: return (String(localized: "在线"), Theme.ok)
        case 2: return (String(localized: "忙碌"), Theme.warn)
        case 3, 4: return (String(localized: "离开"), Theme.warn)
        default:
            if let last = friend?.lastOnline, last > 0 {
                let ago = Self.relative.localizedString(for: Date(timeIntervalSince1970: TimeInterval(last)), relativeTo: Date())
                return (String(localized: "离线 · 最后在线 \(ago)"), Theme.tertiary)
            }
            return (String(localized: "离线"), Theme.tertiary)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 20) {
            if friend != nil, let openChat { link(String(localized: "发送消息")) { openChat(steamID) } }
            link(String(localized: "在 Steam 社区中打开")) { if let profileURL { open(profileURL) } }
            link(String(localized: "查看库存")) { if let url = profileURL?.appendingPathComponent("inventory") { open(url) } }
            if isOwn { link(String(localized: "编辑个人资料")) { editing = true } }
        }
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent) }
            .buttonStyle(.plain)
    }

    // MARK: lists

    private func gamesSection(_ games: [ProfileData.Game]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: String(localized: "最近游戏"))
            VStack(spacing: 0) {
                ForEach(Array(games.enumerated()), id: \.offset) { i, game in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    Button { tap(game) } label: {
                        HStack(spacing: 14) {
                            RemoteImage(url: game.logo, width: 92, height: 35, radius: 2)
                            Text(game.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(game.hoursText).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tap(_ game: ProfileData.Game) {
        if let appid = game.appid, engine.steamApps[appid] != nil { openGame(appid); return }
        if let appid = game.appid, let url = URL(string: "https://store.steampowered.com/app/\(appid)/") { open(url) }
    }

    private func groupsSection(_ groups: [ProfileData.Group]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: String(localized: "群组"))
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    Button {
                        if let slug = group.slug, let url = URL(string: "https://steamcommunity.com/groups/\(slug)") { open(url) }
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: group.avatar, width: 28, height: 28, radius: 3)
                            Text(group.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 12)
                            if group.members > 0 {
                                Text("\(group.members.formatted()) 位成员").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: loading

    private func load(force: Bool) async {
        friend = nil
        if !force, let hit = ProfileDataCache.shared.fresh(steamID) { phase = .loaded(hit) } else { phase = .loading }
        async let persona: Void = loadFriend()
        if case .loaded = phase {} else {
            if let data = await ProfileDataCache.shared.fetch(steamID) { phase = .loaded(data) } else if !Task.isCancelled { phase = .failed }
        }
        await persona
    }

    /// The friend list answers through Windows Steam, which may be slow or offline; the page does not wait on it for long.
    private func loadFriend() async {
        guard !isOwn, engine.uiOnline else { return }
        let ui = engine.ui, id = steamID
        let found = await withTaskGroup(of: SteamUI.Friend?.self) { group in
            group.addTask { try? await ui.friends().first { $0.steamID == id } }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if !Task.isCancelled { friend = found }
    }
}

// MARK: - Data

struct ProfileData: Sendable {
    struct Game: Sendable {
        let name: String
        let appid: UInt32?
        let logo: URL?
        let recent: String
        let total: String

        var hoursText: String {
            let recentValue = Double(recent.replacingOccurrences(of: ",", with: "")) ?? 0
            let totalText = total.isEmpty ? "" : String(localized: "总计 \(total) 小时")
            return recentValue > 0 ? String(localized: "近两周 \(recent) 小时  ·  \(totalText)") : totalText
        }
    }

    struct Group: Sendable {
        let name: String
        let slug: String?
        let avatar: URL?
        let members: Int
    }

    var name = ""
    var onlineState = ""
    var stateMessage = ""
    var isPublic = true
    var avatar: URL?
    var memberSince: String?
    var location = ""
    var realName = ""
    var summary: AttributedString?
    var games: [Game] = []
    var groups: [Group] = []

    /// nil when the answer is not a profile (Steam's error element, or not XML at all).
    static func parse(_ data: Data) -> ProfileData? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.isProfile else { return nil }
        var out = ProfileData()
        out.name = reader.top["steamID"] ?? ""
        out.onlineState = reader.top["onlineState"] ?? ""
        out.stateMessage = reader.top["stateMessage"].map(plain) ?? ""
        out.isPublic = (reader.top["privacyState"] ?? "public") == "public"
        out.avatar = reader.top["avatarFull"].flatMap(URL.init(string:))
        out.memberSince = reader.top["memberSince"].flatMap(localDate)
        out.location = reader.top["location"] ?? ""
        out.realName = reader.top["realname"] ?? ""
        if let html = reader.top["summary"], !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = EulaText.bbcode(EulaText.bbcode(fromHTML: html))
            out.summary = text.characters.isEmpty ? nil : text
        }
        out.games = reader.games.map {
            Game(name: $0["gameName"] ?? "", appid: $0["gameLink"].flatMap { $0.split(separator: "/").last }.flatMap { UInt32($0) },
                 logo: $0["gameLogo"].flatMap(URL.init(string:)), recent: $0["hoursPlayed"] ?? "", total: $0["hoursOnRecord"] ?? "")
        }.filter { !$0.name.isEmpty }
        out.groups = reader.groups.map {
            Group(name: $0["groupName"] ?? "", slug: $0["groupURL"].flatMap { $0.isEmpty ? nil : $0 },
                  avatar: $0["avatarIcon"].flatMap(URL.init(string:)), members: Int($0["memberCount"] ?? "") ?? 0)
        }.filter { !$0.name.isEmpty }
        return out
    }

    /// "In-Game<br/>Name" style status text without its markup.
    private static func plain(_ s: String) -> String {
        let text = EulaText.bbcode(fromHTML: s)
        return text.split(separator: "\n").dropFirst().joined(separator: " ")
    }

    /// Steam writes English dates ("November 10, 2025"; the current year is left out).
    private static func localDate(_ s: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        if let d = f.date(from: s) { return d.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) }
        f.dateFormat = "MMMM d yyyy"
        if let d = f.date(from: "\(s) \(Calendar.current.component(.year, from: Date()))") {
            return d.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
        }
        return nil
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var top: [String: String] = [:]
        var games: [[String: String]] = []
        var groups: [[String: String]] = []
        var isProfile = false
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            if path.count == 1 { isProfile = name == "profile" }
            if path.suffix(2) == ["mostPlayedGames", "mostPlayedGame"] { games.append([:]) }
            if path.suffix(2) == ["groups", "group"] { groups.append([:]) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.count == 2 { top[name] = value }
            else if path.count == 4, path[1] == "mostPlayedGames", !games.isEmpty { games[games.count - 1][name] = value }
            else if path.count == 4, path[1] == "groups", !groups.isEmpty { groups[groups.count - 1][name] = value }
            text = ""
        }
    }
}

/// One fetch per profile and ten minutes; concurrent requests share it, failures are not cached.
@MainActor
private final class ProfileDataCache {
    static let shared = ProfileDataCache()
    private var entries: [String: (data: ProfileData, time: Date)] = [:]
    private var inFlight: [String: Task<ProfileData?, Never>] = [:]

    func fresh(_ id: String) -> ProfileData? {
        guard let e = entries[id], Date().timeIntervalSince(e.time) < 600 else { return nil }
        return e.data
    }

    func fetch(_ id: String) async -> ProfileData? {
        let task = inFlight[id] ?? Task {
            guard let url = URL(string: "https://steamcommunity.com/profiles/\(id)/?xml=1") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return await Task.detached(priority: .userInitiated) { ProfileData.parse(data) }.value
        }
        inFlight[id] = task
        // A view that goes away stops waiting, but the shared fetch finishes and fills the cache.
        let result = await task.value
        inFlight[id] = nil
        if let result { entries[id] = (result, Date()) }
        return result
    }
}

/// Avatars, capsules and group icons: each address is fetched once per run, off the main thread.
@MainActor
private final class ProfileImageCache {
    static let shared = ProfileImageCache()
    private let images = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let img = await Task.detached(priority: .utility, operation: { NSImage(data: data) }).value else { return nil }
        images.setObject(img, forKey: url as NSURL)
        return img
    }
}

private struct RemoteImage: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.surface
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = ProfileImageCache.shared.cached(url)
            guard image == nil else { return }
            for attempt in 0..<2 {
                if let img = await ProfileImageCache.shared.load(url) { image = img; return }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 4))
            }
        }
    }
}
