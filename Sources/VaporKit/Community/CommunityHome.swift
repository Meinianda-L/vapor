import Foundation

// Steam's top-level 社区: the home feed (steamcommunity.com/), general forums and the workshop front.

/// What the home feed can be narrowed to; `rawValue` is the `appHubSubSection` the page's own
/// "load more" form posts to /apps/allcontenthome.
public enum HomeContent: Int, CaseIterable, Sendable, Hashable {
    case all = 11, screenshots = 2, artwork = 4, workshop = 6, guides = 9, videos = 3, broadcasts = 13

    public var title: String {
        switch self {
        case .all: return String(localized: "全部")
        case .screenshots: return String(localized: "截图")
        case .artwork: return String(localized: "艺术作品")
        case .workshop: return String(localized: "创意工坊")
        case .guides: return String(localized: "指南")
        case .videos: return String(localized: "视频")
        case .broadcasts: return String(localized: "实况直播")
        }
    }
}

public struct HomeCard: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case screenshot, artwork, workshop, guide, video, broadcast }
    public let id: String
    public let kind: Kind
    public let title: String
    public let excerpt: String
    public let image: URL?
    public let appid: UInt32?
    public let appName: String
    public let author: String
    public let rating: String
    public let comments: Int?
    public let viewers: String
    public let url: URL
}

public enum CommunityHomeClient {
    /// One page (10 per kind) of the home feed. Without `anonymous` Steam personalises it for the signed-in cookie.
    public static func feed(_ content: HomeContent, recent: Bool, page: Int, anonymous: Bool) -> URL {
        var c = URLComponents(string: "https://steamcommunity.com/apps/allcontenthome/")!
        var items = [URLQueryItem(name: "appHubSubSection", value: "\(content.rawValue)"),
                     URLQueryItem(name: "browsefilter", value: recent ? "mostrecent" : "trend"),
                     URLQueryItem(name: "l", value: "schinese"),
                     URLQueryItem(name: "p", value: "\(page)")]
        if anonymous { items.append(URLQueryItem(name: "forceanon", value: "1")) }
        c.queryItems = items
        return c.url!
    }

    public static let discussions = URL(string: "https://steamcommunity.com/discussions/?l=schinese")!

    public static func workshops(recent: Bool, start: Int, count: Int) -> URL {
        var c = URLComponents(string: "https://steamcommunity.com/sharedfiles/ajaxgetworkshops/")!
        c.queryItems = [URLQueryItem(name: "query", value: recent ? "MostRecent" : "Alphabetical"), URLQueryItem(name: "start", value: "\(start)"),
                        URLQueryItem(name: "count", value: "\(count)"), URLQueryItem(name: "l", value: "schinese")]
        return c.url!
    }
}

public enum CommunityHomeParser {
    private static let kinds: [(String, HomeCard.Kind)] = [
        (String(localized: "截图"), .screenshot), (String(localized: "艺术作品"), .artwork), (String(localized: "创意工坊项目"), .workshop), (String(localized: "指南"), .guide), (String(localized: "视频"), .video), (String(localized: "实况直播"), .broadcast),
    ]

    /// Cards of /apps/allcontenthome. The type line reads "<game>: <kind>", so the kind is its suffix.
    public static func cards(html: String) -> [HomeCard] {
        let root = HTML.parse(html)
        var seen = Set<String>()
        var out: [HomeCard] = []
        for card in root.all(class: "apphub_Card") {
            let typeText = card.first(class: "apphub_CardContentType")?.plainText ?? ""
            guard let kind = kinds.first(where: { typeText.hasSuffix($0.0) })?.1 else { continue }
            var link = CommunityParsers.url(card.attr("data-modal-content-url"))
            if link == nil { link = CommunityParsers.url(card.first(tag: "a")?.attr("href")) }
            guard let link else { continue }
            let id = card.attr("id") ?? link.absoluteString
            guard seen.insert(id).inserted else { continue }

            let appLink = card.first(class: "apphub_CardContentAppName")?.first(tag: "a")
            var appName = appLink?.plainText ?? ""
            if appName.isEmpty, let r = typeText.range(of: ": ", options: .backwards) { appName = String(typeText[..<r.lowerBound]) }
            let appid = card.attr("data-appid").flatMap(UInt32.init)
                ?? appLink?.attr("href").flatMap { $0.firstMatch(#"/app/(\d+)"#)?[1] }.flatMap(UInt32.init)

            var title = "", excerpt = "", image: URL?
            switch kind {
            case .guide:
                let t = card.first(class: "apphub_CardContentGuideTitle")
                title = t?.plainText ?? ""
                image = CommunityParsers.imageURL(in: t)
                excerpt = card.first(class: "apphub_CardContentGuideDesc")?.plainText ?? ""
            default:
                title = card.first(class: "apphub_CardContentTitle")?.plainText ?? ""
                image = card.first(class: "apphub_CardContentPreviewImage").flatMap { CommunityParsers.url($0.attr("src")) }
            }
            let author = card.first(class: "apphub_CardContentAuthorName")?.plainText ?? ""
            let rating = card.first(class: "apphub_CardRating")?.plainText ?? ""
            let comments = CommunityParsers.int(card.first(class: "apphub_CardCommentCount")?.plainText)
            let viewers = card.first(class: "apphub_CardContentViewers")?.plainText ?? ""
            out.append(HomeCard(id: id, kind: kind, title: title, excerpt: excerpt, image: image, appid: appid, appName: appName,
                                author: author, rating: rating, comments: comments, viewers: viewers, url: link))
        }
        return out
    }

    // MARK: Forums index

    public struct ForumRow: Identifiable, Sendable, Equatable {
        public var id: String { url.absoluteString }
        public let name: String
        public let url: URL
        public let topics: String
        public let lastPost: Date?
        public let avatar: URL?
    }

    public struct DiscussionIndex: Sendable, Equatable {
        /// The Steam forums ("New to Steam", "Help and Tips", ...).
        public var forums: [ForumRow]
        /// Feature groups and Valve's own hubs listed beside them.
        public var groups: [ForumRow]
    }

    public static func discussionIndex(html: String) -> DiscussionIndex {
        let root = HTML.parse(html)
        var forums: [ForumRow] = []
        for row in root.all(class: "discussions_forum_row") {
            guard let url = CommunityParsers.url(row.first(class: "discussions_forumlist_linkoverlay")?.first(tag: "a")?.attr("href")) else { continue }
            forums.append(ForumRow(name: row.first(class: "discussions_forumlist_forumname")?.plainText ?? "", url: url,
                                   topics: row.first(class: "discussions_forumlist_topiccount")?.plainText ?? "",
                                   lastPost: CommunityParsers.date(row.first(class: "discussions_forumlist_lastpost")?.first(tag: "span")),
                                   avatar: nil))
        }
        var groups: [ForumRow] = []
        var seen = Set<URL>()
        for a in root.all(class: "recent_game_discussion") {
            guard let url = CommunityParsers.url(a.attr("href")), seen.insert(url).inserted else { continue }
            groups.append(ForumRow(name: a.first(class: "recent_game_discussion_name")?.plainText ?? "", url: url,
                                   topics: a.first(class: "recent_game_discussion_count")?.plainText ?? "", lastPost: nil,
                                   avatar: CommunityParsers.imageURL(in: a)))
        }
        return DiscussionIndex(forums: forums.filter { !$0.name.isEmpty }, groups: groups.filter { !$0.name.isEmpty })
    }

    // MARK: Workshop front

    public struct WorkshopApp: Identifiable, Sendable, Equatable {
        public var id: UInt32 { appid }
        public let appid: UInt32
        public let name: String
        public let logo: URL?
        public let preview: URL?
        public let items: String
        public var url: URL { URL(string: "https://steamcommunity.com/app/\(appid)/workshop/")! }
    }

    public struct WorkshopFront: Sendable, Equatable {
        public var apps: [WorkshopApp]
        public var total: Int
    }

    /// Response of /sharedfiles/ajaxgetworkshops/.
    public static func workshopFront(json data: Data) -> WorkshopFront? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["success"] as? Bool == true,
              let html = obj["results_html"] as? String else { return nil }
        let root = HTML.parse(html)
        var apps: [WorkshopApp] = []
        for a in root.all(class: "app") {
            guard let click = a.attr("onclick"), let m = click.firstMatch(#"/app/(\d+)/workshop"#), let appid = UInt32(m[1]) else { continue }
            let logo = a.first(class: "appLogo")
            var preview: URL?
            if let style = a.first(class: "itemPreviewHolder")?.attr("style"), let u = style.firstMatch(#"url\('([^']+)'\)"#) {
                preview = CommunityParsers.url(u[1])
            }
            if preview?.absoluteString.contains("steam_workshop_default_image") == true { preview = nil }
            apps.append(WorkshopApp(appid: appid, name: logo?.attr("alt") ?? "", logo: CommunityParsers.url(logo?.attr("src")), preview: preview,
                                    items: a.first(class: "appNumItems")?.plainText ?? ""))
        }
        let total = (obj["total_count"] as? Int) ?? apps.count
        return WorkshopFront(apps: apps, total: total)
    }
}
