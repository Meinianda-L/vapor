import Foundation

/// The tabs of an app's community hub.
public enum CommunityTab: String, CaseIterable, Sendable, Hashable {
    case all, discussions, guides, workshop, screenshots, artwork

    public var title: String {
        switch self {
        case .all: return "全部"
        case .discussions: return "讨论"
        case .guides: return "指南"
        case .workshop: return "创意工坊"
        case .screenshots: return "截图"
        case .artwork: return "艺术作品"
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
            guard parts.count >= 3, parts[2] == "inventory", parts[1].count == 17, parts[1].allSatisfy(\.isNumber) else { return nil }
            var appid: UInt32?
            if let frag = url.fragment, let first = frag.split(separator: "_").first { appid = UInt32(first) }
            return .inventory(steamID: parts[1], appid: appid)
        default:
            return nil
        }
    }
}
