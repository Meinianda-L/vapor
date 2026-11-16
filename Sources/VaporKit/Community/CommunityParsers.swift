import Foundation

// MARK: - Hub

public struct CommunityCard: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case discussion, guide, workshop, screenshot, artwork, news }
    public let id: String
    public let kind: Kind
    public let title: String
    public let excerpt: String
    public let image: URL?
    public let author: String
    public let comments: Int?
    public let url: URL
    /// Set for cards that open a shared file (item, guide, screenshot, artwork).
    public let fileID: UInt64?
}

public struct CommunityHub: Sendable, Equatable {
    public var appName: String
    public var tabs: [CommunityTab]
    public var cards: [CommunityCard]
}

public enum CommunityParsers {
    static func int(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func date(_ node: HTMLNode?) -> Date? {
        guard let t = node?.attr("data-timestamp").flatMap(TimeInterval.init) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func url(_ s: String?) -> URL? { s.flatMap { RichText.resolve($0, base: URL(string: "https://steamcommunity.com/")) } }

    static func fileID(in url: URL) -> UInt64? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value.flatMap(UInt64.init)
    }

    /// The first `src` of an image inside `node`, without Steam's tiny-thumbnail query.
    static func imageURL(in node: HTMLNode?) -> URL? {
        guard let src = node?.first(tag: "img")?.attr("src") else { return nil }
        return url(src)
    }

    // MARK: Hub page

    public static func hub(html: String, appid: UInt32) -> CommunityHub {
        let root = HTML.parse(html)
        let name = root.first(class: "apphub_AppName")?.plainText ?? ""
        var tabs: [CommunityTab] = [.all]
        for a in root.all(class: "apphub_sectionTab") {
            let href = a.attr("href") ?? ""
            for tab in CommunityTab.allCases {
                guard let seg = tab.segment, !tabs.contains(tab) else { continue }
                if href.contains("/app/\(appid)/\(seg)") { tabs.append(tab) }
            }
        }
        tabs.sort { CommunityTab.allCases.firstIndex(of: $0)! < CommunityTab.allCases.firstIndex(of: $1)! }
        return CommunityHub(appName: name, tabs: tabs, cards: cards(in: root))
    }

    public static func cards(html: String) -> [CommunityCard] { cards(in: HTML.parse(html)) }

    /// Cards of a hub feed or a screenshots / artwork browse page.
    public static func cards(in root: HTMLNode) -> [CommunityCard] {
        var seen = Set<String>()
        var out: [CommunityCard] = []
        for card in root.all(class: "apphub_Card") {
            guard let link = url(card.attr("data-modal-content-url")) else { continue }
            let path = link.path
            let typeNode = card.first(class: "apphub_CardContentType")
            let typeText = typeNode?.plainText ?? ""
            var kind: CommunityCard.Kind
            if path.contains("/discussions/") { kind = .discussion }
            else if path.contains("/announcements/") { kind = .news }
            else if path.contains("/filedetails") {
                if typeNode?.hasClass("guide") == true || typeText == "指南" { kind = .guide }
                else if typeText == "截图" { kind = .screenshot }
                else if typeText == "艺术作品" { kind = .artwork }
                else if typeText.contains("创意工坊") { kind = .workshop }
                else { continue }                       // videos, broadcasts
            } else { continue }                         // reviews and the rest
            let id = card.attr("id") ?? link.absoluteString
            guard seen.insert(id).inserted else { continue }

            var title = "", excerpt = "", image: URL?
            switch kind {
            case .discussion:
                title = card.first(class: "apphub_CardContentDiscussionTitle")?.plainText ?? ""
                excerpt = card.first(class: "apphub_CardTextContent")?.plainText ?? ""
            case .news:
                title = card.first(class: "apphub_CardContentNewsTitle")?.plainText ?? ""
                excerpt = card.first(class: "apphub_CardTextContent")?.plainText ?? ""
                image = imageURL(in: card.first(class: "appHubNewsIconHolder"))
            case .guide:
                let t = card.first(class: "apphub_CardContentGuideTitle")
                title = t?.plainText ?? ""
                image = imageURL(in: t)
                excerpt = card.first(class: "apphub_CardContentGuideDesc")?.plainText ?? ""
            default:
                title = card.first(class: "apphub_CardContentTitle")?.plainText ?? ""
                image = imageURL(in: card.first(class: "apphub_CardContentPreviewImageBorder"))
            }
            let author = card.first(class: "apphub_CardContentAuthorName")?.plainText ?? ""
            let comments = int(card.first(class: "apphub_CardCommentCount")?.plainText)
            let fid = kind == .discussion || kind == .news ? nil : fileID(in: link)
            out.append(CommunityCard(id: id, kind: kind, title: title, excerpt: excerpt, image: image, author: author, comments: comments, url: link, fileID: fid))
        }
        return out
    }

    // MARK: Forums

    public struct ForumRef: Sendable, Equatable, Identifiable {
        public var id: String { url.absoluteString }
        public let name: String
        public let url: URL
        public let selected: Bool
    }

    public struct ForumTopic: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let author: String
        public let replies: Int
        public let lastPost: Date?
        public let pinned: Bool
        public let locked: Bool
        public let url: URL
    }

    public struct ForumListing: Sendable, Equatable {
        public var forumName: String
        public var forums: [ForumRef]
        public var topics: [ForumTopic]
        public var start: Int
        public var total: Int
        public var pageSize: Int
        /// Forum id that search is scoped to.
        public var gidForum: String?
        public var page: Int { pageSize > 0 ? start / pageSize + 1 : 1 }
        public var pageCount: Int { pageSize > 0 ? max(1, (total + pageSize - 1) / pageSize) : 1 }
    }

    /// A forum page or a discussion search result page.
    public static func forum(html: String) -> ForumListing {
        let root = HTML.parse(html)
        var forums: [ForumRef] = []
        if let select = root.first(class: "forumselector")?.first(tag: "select") {
            for o in select.all(tag: "option") {
                if let u = url(o.attr("value")) { forums.append(ForumRef(name: o.plainText, url: u, selected: o.attrs["selected"] != nil)) }
            }
        }
        var topics: [ForumTopic] = []
        for t in root.all(class: "forum_topic") {
            guard let id = t.attr("data-gidforumtopic"), let link = url(t.first(class: "forum_topic_overlay")?.attr("href")) else { continue }
            let nameNode = t.first(class: "forum_topic_name")
            let labels = nameNode?.all(class: "forum_topic_label") ?? []
            let pinned = t.hasClass("sticky") || labels.contains { $0.hasClass("sticky_label") }
            let locked = t.hasClass("locked") || labels.contains { $0.hasClass("locked_label") }
            var title = nameNode?.plainText ?? ""
            for l in labels { let lt = l.plainText; if let r = title.range(of: lt) { title.removeSubrange(r) } }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var author = t.first(class: "forum_topic_op")?.plainText ?? ""
            var last = date(t.first(class: "forum_topic_lastpost"))
            if let holder = t.parent, holder.hasClass("post_searchresult") || holder.parent?.hasClass("post_searchresult") == true {
                if let a = holder.first(class: "searchresult_author")?.first(class: "whiteLink") { author = a.plainText }
                if last == nil { last = date(holder.first(class: "searchresult_timestamp")) }
            }
            topics.append(ForumTopic(id: id, title: title, author: author, replies: int(t.first(class: "forum_topic_reply_count")?.plainText) ?? 0,
                                     lastPost: last, pinned: pinned, locked: locked, url: link))
        }
        var start = 0, total = topics.count, size = max(topics.count, 15), gid: String?
        if let m = html.firstMatch(#"InitializeForum\([^{]*\{[^}]*?"gidforum":"(\d+)"[^}]*?\}"#) {
            gid = m[1]
            let blob = m[0]
            start = blob.firstMatch(#""start":(\d+)"#).flatMap { Int($0[1]) } ?? 0
            total = blob.firstMatch(#""total_count":(\d+)"#).flatMap { Int($0[1]) } ?? total
            size = blob.firstMatch(#""pagesize":(\d+)"#).flatMap { Int($0[1]) } ?? size
        } else if let m = html.firstMatch(#"第\s*([\d,]+)\s*-\s*([\d,]+)\s*项，共\s*([\d,]+)\s*项"#) {
            // search results: "正在显示第 1 - 10 项，共 46,249 项条目"
            start = (int(m[1]) ?? 1) - 1
            size = max(1, (int(m[2]) ?? 0) - start)
            total = int(m[3]) ?? total
            gid = html.firstMatch(#"name="gidforum" value="(\d+)""#)?[1]
            if size < 10 { size = 10 }
        }
        let name = forums.first { $0.selected }?.name ?? ""
        return ForumListing(forumName: name, forums: forums, topics: topics, start: start, total: total, pageSize: size, gidForum: gid)
    }

    public struct ForumPost: Sendable, Equatable, Identifiable {
        public let id: String
        public let author: String
        public let authorURL: URL?
        public let avatar: URL?
        public let date: Date?
        public let number: String?
        public let blocks: [RichBlock]
    }

    public struct ForumThread: Sendable, Equatable {
        public var title: String
        public var forumName: String
        public var forumURL: URL?
        public var opening: ForumPost?
        public var replies: [ForumPost]
        public var start: Int
        public var total: Int
        public var pageSize: Int
        public var page: Int { pageSize > 0 ? start / pageSize + 1 : 1 }
        public var pageCount: Int { pageSize > 0 ? max(1, (total + pageSize - 1) / pageSize) : 1 }
    }

    static func avatar(in node: HTMLNode?) -> URL? {
        guard let node else { return nil }
        let imgs = node.all(tag: "img").compactMap { $0.attr("src") }
        return url(imgs.last { $0.contains("avatars.") } ?? imgs.last { $0.contains("avatar") })
    }

    public static func thread(html: String) -> ForumThread? {
        let root = HTML.parse(html)
        let base = URL(string: "https://steamcommunity.com/")
        var opening: ForumPost?
        var title = ""
        if let op = root.first(class: "forum_op") {
            title = op.first(class: "topic")?.plainText ?? ""
            let a = op.first(class: "forum_op_author")
            let id = (op.attr("id") ?? "").replacingOccurrences(of: "forum_op_", with: "")
            let content = op.first(class: "content").map { RichText.blocks(node: $0, base: base) } ?? []
            opening = ForumPost(id: id, author: a?.plainText ?? "", authorURL: url(a?.attr("href")), avatar: avatar(in: op.first(class: "forum_op_avatar")),
                                date: date(op.first(class: "date")), number: nil, blocks: content)
        }
        var replies: [ForumPost] = []
        for c in root.all(class: "commentthread_comment") {
            guard let textNode = c.first(class: "commentthread_comment_text") else { continue }
            let link = c.first(class: "commentthread_author_link")
            let stamp = c.all { $0.attr("data-timestamp") != nil }.first
            replies.append(ForumPost(id: (c.attr("id") ?? "").replacingOccurrences(of: "comment_", with: ""),
                                     author: link?.plainText ?? "", authorURL: url(link?.attr("href")),
                                     avatar: avatar(in: c.first(class: "commentthread_comment_avatar")), date: date(stamp),
                                     number: c.first(class: "forum_comment_permlink")?.first(tag: "a")?.plainText,
                                     blocks: RichText.blocks(node: textNode, base: base)))
        }
        guard opening != nil || !replies.isEmpty else { return nil }
        var start = 0, total = replies.count, size = 15
        if let m = html.firstMatch(#""total_count":(\d+),"start":(\d+),"pagesize":(\d+)"#) {
            total = Int(m[1]) ?? total; start = Int(m[2]) ?? 0; size = Int(m[3]) ?? size
        }
        let crumbs = root.first(class: "forum_breadcrumbs")?.all(tag: "a") ?? []
        let forum = crumbs.dropFirst().first
        return ForumThread(title: title, forumName: forum?.plainText ?? "", forumURL: url(forum?.attr("href")), opening: opening, replies: replies,
                           start: start, total: total, pageSize: size)
    }

    // MARK: Shared files

    public struct SharedFileCard: Identifiable, Sendable, Equatable {
        public let id: UInt64
        public let title: String
        public let author: String
        public let preview: URL?
        public let stars: Int?
        public let summary: String
        public var subscriptions: Int?
        public var size: Int64?
        public var tags: [String] = []
    }

    public struct SharedFileListing: Sendable, Equatable {
        public var items: [SharedFileCard]
        public var total: Int
        public var page: Int
        public var pageSize: Int
        public var pageCount: Int { pageSize > 0 ? max(1, (total + pageSize - 1) / pageSize) : 1 }
    }

    static func stars(from src: String?) -> Int? {
        guard let src, let m = src.firstMatch(#"/(\d)-star"#) else { return nil }
        return Int(m[1])
    }

    /// The old server-rendered list (guides, and anything else built from `workshopItemCollectionContainer`).
    public static func sharedFileList(html: String, page: Int) -> SharedFileListing {
        let root = HTML.parse(html)
        var items: [SharedFileCard] = []
        for c in root.all(class: "workshopItemCollection") {
            guard let id = c.attr("data-publishedfileid").flatMap(UInt64.init) else { continue }
            items.append(SharedFileCard(id: id, title: c.first(class: "workshopItemTitle")?.plainText ?? "",
                                        author: c.first(class: "workshopItemAuthorName")?.plainText ?? "",
                                        preview: url(c.first(class: "workshopItemPreviewImage")?.attr("src")),
                                        stars: stars(from: c.first(class: "fileRating")?.attr("src")),
                                        summary: c.first(class: "workshopItemShortDesc")?.plainText ?? ""))
        }
        var total = items.count, size = max(items.count, 1)
        if let m = html.firstMatch(#"第\s*([\d,]+)\s*-\s*([\d,]+)\s*项，共\s*([\d,]+)\s*项"#) {
            total = int(m[3]) ?? total
            let from = int(m[1]) ?? 1, to = int(m[2]) ?? items.count
            size = page <= 1 ? max(to - from + 1, items.count) : max(1, (from - 1) / max(page - 1, 1))
        }
        return SharedFileListing(items: items, total: total, page: page, pageSize: size)
    }

    public struct Stat: Sendable, Equatable { public let label: String; public let value: String }

    public struct GuideSection: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let blocks: [RichBlock]
    }

    public struct SharedFile: Sendable, Equatable {
        public enum Kind: Sendable { case item, guide, media }
        public var kind: Kind
        public var title: String
        public var appid: UInt32?
        public var author: String
        public var authorURL: URL?
        public var authorAvatar: URL?
        public var stars: Int?
        public var ratingNote: String
        public var images: [URL]
        public var description: [RichBlock]
        public var sections: [GuideSection]
        public var stats: [Stat]
        public var tags: [String]
        public var coAuthors: String
    }

    public static func sharedFile(html: String) -> SharedFile? {
        let root = HTML.parse(html)
        let base = URL(string: "https://steamcommunity.com/")
        let isGuide = root.first { $0.hasClass("guide") && $0.hasClass("subSections") } != nil
        let media = root.first(id: "ActualMedia")
        guard isGuide || media != nil || root.first(class: "workshopItemTitle") != nil else { return nil }

        let creator = root.first(class: "creatorsBlock")?.first(class: "friendBlock")
        var author = ""
        if let content = creator?.first(class: "friendBlockContent"), let t = content.children.first(where: { $0.isText && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            author = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let authorURL = url(creator?.first(class: "friendBlockLinkOverlay")?.attr("href"))
        let authorAvatar = creator.flatMap { avatar(in: $0.first(class: "playerAvatar")) }
        var appid = (root.first(id: "sharedfiles_content_ctn")?.attr("data-miniprofile-appid")).flatMap(UInt32.init)
        if appid == nil, let m = html.firstMatch(#"/app/(\d+)(?:/|")"#) { appid = UInt32(m[1]) }

        var stats: [Stat] = []
        if let block = root.all(class: "rightDetailsBlock").first(where: { $0.first(class: "detailsStatsContainerLeft") != nil }) {
            let l = block.first(class: "detailsStatsContainerLeft")?.all(class: "detailsStatLeft").map(\.plainText) ?? []
            let r = block.first(class: "detailsStatsContainerRight")?.all(class: "detailsStatRight").map(\.plainText) ?? []
            for (a, b) in zip(l, r) where !a.isEmpty && !b.isEmpty { stats.append(Stat(label: a, value: b)) }
        }
        for row in root.first(class: "stats_table")?.all(tag: "tr") ?? [] {
            let tds = row.all(tag: "td").map(\.plainText)
            if tds.count == 2 { stats.append(Stat(label: tds[1], value: tds[0])) }
        }
        let ratingBlock = root.first(class: "ratingSection") ?? root.first(class: "workshopItemRatings")
        let rating = stars(from: (root.first(class: "fileRatingDetails") ?? ratingBlock)?.first(tag: "img")?.attr("src"))
        var note = root.first(class: "numRatings")?.plainText ?? ""
        if note.isEmpty, let up = root.first(id: "VotesUpCount")?.plainText, !up.isEmpty { note = "\(up) 个赞" }
        if note.isEmpty, isGuide { note = ratingBlock?.plainText ?? "" }

        var file = SharedFile(kind: isGuide ? .guide : media != nil ? .media : .item, title: "", appid: appid, author: author, authorURL: authorURL, authorAvatar: authorAvatar,
                              stars: rating, ratingNote: note, images: [], description: [], sections: [], stats: stats,
                              tags: root.first(class: "workshopTags")?.all(tag: "a").map(\.plainText) ?? [], coAuthors: "")
        if isGuide {
            let top = root.first(class: "guideTop")
            file.title = top?.first(class: "workshopItemTitle")?.plainText ?? ""
            file.coAuthors = top?.first(class: "guideAuthors")?.plainText ?? ""
            file.images = [imageURL(in: top?.first(class: "guidePreviewImage"))].compactMap { $0 }
            file.description = top?.first(class: "guideTopDescription").map { RichText.blocks(node: $0, base: base) } ?? []
            for s in root.all(class: "subSection") {
                let title = s.first(class: "subSectionTitle")?.plainText ?? ""
                let body = s.first(class: "subSectionDesc").map { RichText.blocks(node: $0, base: base) } ?? []
                file.sections.append(GuideSection(id: s.attr("id") ?? "\(file.sections.count)", title: title, blocks: body))
            }
        } else {
            file.title = root.first(class: "workshopItemTitle")?.plainText ?? ""
            if file.title.isEmpty { file.title = HTML.decode(html.firstMatch(#"<title>[^:]*::\s*([^<]*)</title>"#)?[1] ?? "") }
            if let m = media {
                let full = m.parent?.attr("href")
                let fit = (full ?? m.attr("src") ?? "").replacingOccurrences(of: #"imw=\d+&imh=\d+"#, with: "imw=1920&imh=1080", options: .regularExpression)
                file.images = [url(fit)].compactMap { $0 }
            } else {
                var images: [URL] = []
                if let src = root.first(id: "previewImage")?.attr("src") {
                    let big = src.replacingOccurrences(of: #"imw=\d+&imh=\d+"#, with: "imw=1280&imh=720", options: .regularExpression)
                    if let u = url(big) { images.append(u) }
                }
                if let list = html.firstMatch(#"rgFullScreenshotURLs\s*=\s*\[([^\]]*)\]"#)?[1] {
                    for m in list.matches(#"'(https?://[^']+)'"#) { if let u = url(m[1]), !images.contains(u) { images.append(u) } }
                }
                file.images = images
            }
            file.description = root.first(class: "workshopItemDescription").map { RichText.blocks(node: $0, base: base) } ?? []
            if file.description.isEmpty, let d = root.first(class: "screenshotDescription") { file.description = RichText.blocks(node: d, base: base) }
        }
        return file
    }
}

// MARK: - Workshop browse (server-side rendered React state)

public struct WorkshopListing: Sendable, Equatable {
    public var items: [CommunityParsers.SharedFileCard]
    public var total: Int
    public var page: Int
    public var pageCount: Int
}

public enum WorkshopParser {
    /// The browse page ships its query cache as JSON in `<script id="valve-ssr-data">`.
    public static func listing(html: String) -> WorkshopListing? {
        for body in ssrBodies(html) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let ctx = obj["renderContext"] as? [String: Any] else { continue }
            var queryData = ctx["queryData"]
            if let s = queryData as? String { queryData = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
            guard let queries = (queryData as? [String: Any])?["queries"] as? [[String: Any]] else { continue }

            var names: [String: String] = [:]
            var found: [String: Any]?
            for q in queries {
                guard let key = q["queryKey"] as? [Any], let kind = key.first as? String,
                      let data = (q["state"] as? [String: Any])?["data"] as? [String: Any] else { continue }
                if kind == "workshop_browse" { found = data }
                if kind == "PlayerLinkDetails", let id = key.dropFirst().first as? String,
                   let name = (data["public_data"] as? [String: Any])?["persona_name"] as? String { names[id] = name }
            }
            guard let data = found, let results = data["results"] as? [[String: Any]] else { continue }
            let items: [CommunityParsers.SharedFileCard] = results.compactMap { r in
                guard let id = (r["publishedfileid"] as? String).flatMap(UInt64.init) else { return nil }
                let preview = (r["preview_url"] as? String).flatMap { URL(string: $0.contains("?") ? $0 : $0 + "?imw=512&imh=288&ima=fit&impolicy=Letterbox&imcolor=%23000000&letterbox=false") }
                let tags = (r["tags"] as? [[String: Any]])?.compactMap { ($0["display_name"] as? String) ?? ($0["tag"] as? String) } ?? []
                let size = (r["file_size"] as? String).flatMap(Int64.init) ?? (r["file_size"] as? Int64)
                return CommunityParsers.SharedFileCard(id: id, title: r["title"] as? String ?? "", author: names[r["creator"] as? String ?? ""] ?? "",
                                                       preview: preview, stars: (r["star_rating"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                                                       summary: r["short_description"] as? String ?? "", subscriptions: r["subscriptions"] as? Int,
                                                       size: size, tags: tags)
            }
            let total = data["total_count"] as? Int ?? items.count
            return WorkshopListing(items: items, total: total, page: data["current_page"] as? Int ?? 1,
                                   pageCount: max(1, min(data["total_pages"] as? Int ?? 1, (total + 29) / 30)))
        }
        return nil
    }

    static func ssrBodies(_ html: String) -> [String] {
        var out: [String] = []
        var from = html.startIndex
        while let r = html.range(of: #"id="valve-ssr-data""#, range: from..<html.endIndex),
              let open = html.range(of: ">", range: r.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) {
            out.append(String(html[open.upperBound..<close.lowerBound]))
            from = close.upperBound
        }
        return out
    }
}

// MARK: - Inventory

public struct InventoryApp: Identifiable, Sendable, Equatable {
    public struct Context: Sendable, Equatable { public let id: String; public let name: String; public let count: Int }
    public var id: UInt32 { appid }
    public let appid: UInt32
    public let name: String
    public let icon: URL?
    public let count: Int
    public let contexts: [Context]
}

public struct InventoryItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let color: String
    public let icon: URL?
    public let lines: [String]
    public let tags: [String]
    public let tradable: Bool
    public let marketable: Bool
    public var count: Int
}

public struct InventoryPage: Sendable, Equatable {
    public var items: [InventoryItem]
    public var total: Int
    public var next: String?
}

public enum InventoryParser {
    /// Games with inventories, from the profile's inventory page (`g_rgAppContextData`).
    public static func apps(html: String) -> [InventoryApp] {
        guard let marker = html.range(of: "g_rgAppContextData = ") else { return [] }
        guard let json = balanced(html, from: marker.upperBound), let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        var out: [InventoryApp] = []
        for (_, v) in obj {
            guard let d = v as? [String: Any], let appid = d["appid"] as? Int else { continue }
            let ctxs = (d["rgContexts"] as? [String: Any] ?? [:]).compactMap { _, c -> InventoryApp.Context? in
                guard let c = c as? [String: Any], let id = c["id"] as? String, (c["hide_context"] as? Bool) != true else { return nil }
                return InventoryApp.Context(id: id, name: c["name"] as? String ?? id, count: c["asset_count"] as? Int ?? 0)
            }.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
            out.append(InventoryApp(appid: UInt32(appid), name: d["name"] as? String ?? "", icon: (d["icon"] as? String).flatMap(URL.init(string:)),
                                    count: d["asset_count"] as? Int ?? 0, contexts: ctxs))
        }
        return out.filter { $0.count > 0 }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static func balanced(_ s: String, from: String.Index) -> String? {
        guard from < s.endIndex, s[from] == "{" else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = from
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(s[from...i]) } }
            i = s.index(after: i)
        }
        return nil
    }

    public static func items(json data: Data) -> InventoryPage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (obj["success"] as? Int) == 1 || obj["assets"] != nil else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        var descs: [String: [String: Any]] = [:]
        for d in obj["descriptions"] as? [[String: Any]] ?? [] {
            descs["\(d["classid"] ?? "")_\(d["instanceid"] ?? "")"] = d
        }
        var items: [InventoryItem] = []
        var index: [String: Int] = [:]
        for a in assets {
            let key = "\(a["classid"] ?? "")_\(a["instanceid"] ?? "")"
            let amount = (a["amount"] as? String).flatMap(Int.init) ?? 1
            if let i = index[key] { items[i].count += amount; continue }
            guard let d = descs[key] else { continue }
            let lines = (d["descriptions"] as? [[String: Any]] ?? []).compactMap { l -> String? in
                guard let v = l["value"] as? String else { return nil }
                let t = HTML.parse(v).plainText
                return t.isEmpty ? nil : t
            }
            let tags = (d["tags"] as? [[String: Any]] ?? []).compactMap { $0["localized_tag_name"] as? String }
            let icon = (d["icon_url"] as? String).flatMap { URL(string: "https://community.akamai.steamstatic.com/economy/image/\($0)/192fx192f") }
            index[key] = items.count
            items.append(InventoryItem(id: "\(a["assetid"] ?? key)", name: d["name"] as? String ?? d["market_name"] as? String ?? "", type: d["type"] as? String ?? "",
                                       color: d["name_color"] as? String ?? "", icon: icon, lines: lines, tags: tags,
                                       tradable: (d["tradable"] as? Int) == 1, marketable: (d["marketable"] as? Int) == 1, count: amount))
        }
        let more = (obj["more_items"] as? Int) == 1
        return InventoryPage(items: items, total: obj["total_inventory_count"] as? Int ?? items.count, next: more ? obj["last_assetid"] as? String : nil)
    }
}

// MARK: - Points shop

public struct RewardItem: Identifiable, Sendable, Equatable {
    public let id: UInt64
    public let name: String
    public let title: String
    public let summary: String
    public let cost: Int
    public let image: URL?
    public let animated: Bool
}

public struct RewardPage: Sendable, Equatable {
    public var items: [RewardItem]
    public var total: Int
    public var cursor: String?
    /// Definitions the server returned, including bundles that are not listed.
    public var fetched: Int
}

public enum RewardsParser {
    public static func page(json data: Data, appid: UInt32) -> RewardPage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["response"] as? [String: Any] else { return nil }
        var items: [RewardItem] = []
        for d in root["definitions"] as? [[String: Any]] ?? [] {
            guard (d["active"] as? Bool) != false, let cost = (d["point_cost"] as? String).flatMap(Int.init), cost > 0,
                  let info = d["community_item_data"] as? [String: Any], let defid = d["defid"] as? Int else { continue }
            let name = info["item_name"] as? String ?? ""
            guard !name.isEmpty else { continue }
            let animated = (info["animated"] as? Bool) == true
            let file = animated ? info["item_image_large"] as? String : (info["item_image_small"] as? String ?? info["item_image_large"] as? String)
            let a = d["appid"] as? Int ?? Int(appid)
            items.append(RewardItem(id: UInt64(defid), name: name, title: info["item_title"] as? String ?? "", summary: info["item_description"] as? String ?? "", cost: cost,
                                    image: file.flatMap { URL(string: "https://shared.akamai.steamstatic.com/community_assets/images/items/\(a)/\($0)") }, animated: animated))
        }
        let cursor = root["next_cursor"] as? String
        return RewardPage(items: items, total: root["total_count"] as? Int ?? items.count, cursor: (cursor?.isEmpty == false) ? cursor : nil,
                          fetched: (root["definitions"] as? [Any])?.count ?? 0)
    }
}

// MARK: - Regex helpers

extension String {
    /// Capture groups of the first match, group 0 being the whole match.
    func firstMatch(_ pattern: String) -> [String]? { matches(pattern, limit: 1).first }

    func matches(_ pattern: String, limit: Int = .max) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = self as NSString
        var out: [[String]] = []
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
            if out.count >= limit { break }
        }
        return out
    }
}
