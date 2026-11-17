import Foundation

/// The tabs of an app's community hub.
public enum CommunityTab: String, CaseIterable, Sendable, Hashable {
    case all, discussions, guides, workshop, screenshots, artwork

    public var title: String {
        switch self {
        case .all: return String(localized: "全部")
        case .discussions: return String(localized: "讨论")
        case .guides: return String(localized: "指南")
        case .workshop: return String(localized: "创意工坊")
        case .screenshots: return String(localized: "截图")
        case .artwork: return String(localized: "艺术作品")
        }
    }

    /// Path segment under /app/<id>/ that Steam links the tab to.
    var segment: String? {
        switch self {
        case .all: return nil
        case .discussions: return "discussions"
        case .guides: return "guides"
        case .workshop: return "workshop"
        case .screenshots: return "screenshots"
        case .artwork: return "images"
        }
    }
}

/// Who a community link is about.
public enum UserRef: Hashable, Sendable {
    case id(String)
    case vanity(String)
    /// `/my/…`: the signed-in account.
    case me
}

public enum UserSection: Hashable, Sendable {
    case profile
    case editProfile
    case inventory(appid: UInt32?)
    case tradeOffers(sent: Bool)
}

/// A native destination for a Steam community link.
public enum CommunityPage: Hashable, Sendable {
    case hub(appid: UInt32, tab: CommunityTab)
    /// `forum` is a forum URL as Steam lists it, `topic` a thread URL; both optional.
    case discussions(appid: UInt32, forum: URL?, topic: URL?)
    case guides(appid: UInt32)
    case workshop(appid: UInt32)
    /// A workshop item, guide, screenshot or artwork; the page decides which from its content.
    case sharedFile(id: UInt64)
    case inventory(steamID: String, appid: UInt32?)
    case pointsShop(appid: UInt32)
    /// A page of a user named by vanity URL, by id, or as "my": needs `VanityResolver` / the signed-in account to become an id.
    case user(UserRef, UserSection)

    /// Recognises the Steam web addresses that have a native page; nil for everything else.
    public static func page(for url: URL) -> CommunityPage? {
        let host = (url.host ?? "").lowercased()
        if url.scheme == "steam" {
            // steam://url/CommunityFilePage/<id>
            let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            if parts.count >= 3, parts[0] == "url", parts[1] == "CommunityFilePage", let id = UInt64(parts[2]) { return .sharedFile(id: id) }
            return nil
        }
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }

        if host == "store.steampowered.com" {
            if parts.count >= 4, parts[0] == "points", parts[1] == "shop", parts[2] == "app", let id = UInt32(parts[3]) { return .pointsShop(appid: id) }
            return nil
        }
        guard host == "steamcommunity.com" || host == "www.steamcommunity.com" else { return nil }
        guard let head = parts.first else { return nil }

        switch head {
        case "app", "games":
            guard parts.count >= 2, let appid = UInt32(parts[1]) else { return nil }
            guard parts.count >= 3 else { return .hub(appid: appid, tab: .all) }
            switch parts[2] {
            case "discussions":
                if parts.count >= 4 {
                    // /discussions/<forum>/ or /discussions/<forum>/<topic>/
                    if parts.count >= 5, parts[4].allSatisfy(\.isNumber) { return .discussions(appid: appid, forum: nil, topic: url) }
                    if parts[3] == "search" { return .discussions(appid: appid, forum: nil, topic: nil) }
                    return .discussions(appid: appid, forum: url, topic: nil)
                }
                return .discussions(appid: appid, forum: nil, topic: nil)
            case "tradingforum", "eventcomments": return .discussions(appid: appid, forum: url, topic: nil)
            case "guides": return .guides(appid: appid)
            case "workshop": return .workshop(appid: appid)
            case "screenshots": return .hub(appid: appid, tab: .screenshots)
            case "images": return .hub(appid: appid, tab: .artwork)
            default: return nil
            }
        case "sharedfiles", "workshop":
            guard parts.count >= 2 else { return nil }
            if parts[1] == "filedetails", let id = q("id").flatMap(UInt64.init) { return .sharedFile(id: id) }
            if head == "workshop", parts[1] == "browse", let appid = q("appid").flatMap(UInt32.init) { return .workshop(appid: appid) }
            if head == "workshop", parts[1] == "discussions", let appid = q("appid").flatMap(UInt32.init) { return .discussions(appid: appid, forum: url, topic: nil) }
            return nil
        case "profiles":
            guard parts.count >= 3, parts[1].count == 17, parts[1].allSatisfy(\.isNumber) else { return nil }
            if parts[2] == "inventory" { return .inventory(steamID: parts[1], appid: inventoryApp(url)) }
            return userSection(parts.dropFirst(2), url).map { .user(.id(parts[1]), $0) }
        case "id":
            guard parts.count >= 2 else { return nil }
            let rest = parts.dropFirst(2)
            return userSection(rest, url).map { .user(.vanity(parts[1]), $0) }
        case "my":
            return userSection(parts.dropFirst(), url).map { .user(.me, $0) }
        default:
            return nil
        }
    }

    private static func inventoryApp(_ url: URL) -> UInt32? {
        url.fragment.flatMap { $0.split(separator: "_").first }.flatMap { UInt32($0) }
    }

    /// What follows /id/<name>/, /my/ or /profiles/<id>/ . Pages Vapor has no screen for (friends, games …) give nil.
    private static func userSection(_ rest: ArraySlice<String>, _ url: URL) -> UserSection? {
        guard let first = rest.first else { return .profile }
        switch first {
        case "inventory": return .inventory(appid: inventoryApp(url))
        case "tradeoffers": return .tradeOffers(sent: rest.dropFirst().first == "sent")
        case "edit": return .editProfile
        case "commentnotifications", "home", "profile": return .profile
        default: return nil
        }
    }
}
