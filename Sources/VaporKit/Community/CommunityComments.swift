import Foundation

/// A comment thread under a profile, workshop item, guide or screenshot: where it lives on
/// steamcommunity.com, read from the thread's own initialisation on the page that shows it.
public struct CommentThread: Hashable, Sendable {
    /// "Profile", "PublishedFile_Public", "UserStatusPublished" …
    public let type: String
    public let owner: String
    public let feature: String
    public let feature2: String
    public let total: Int
    /// The page's own `extended_data` string, which Steam wants back when a comment is posted.
    public let extendedData: String?

    public init(type: String, owner: String, feature: String, feature2: String = "-1", total: Int = 0, extendedData: String? = nil) {
        self.type = type; self.owner = owner; self.feature = feature; self.feature2 = feature2
        self.total = total; self.extendedData = extendedData
    }

    /// A profile's own wall.
    public static func profile(_ steamID: String) -> CommentThread { CommentThread(type: "Profile", owner: steamID, feature: "-1") }

    public var renderURL: URL { URL(string: "https://steamcommunity.com/comment/\(type)/render/\(owner)/\(feature)/")! }
    public var postURL: URL { URL(string: "https://steamcommunity.com/comment/\(type)/post/\(owner)/\(feature)/")! }
}

public struct CommunityComment: Identifiable, Sendable, Equatable {
    public let id: String
    public let author: String
    public let authorURL: URL?
    public let avatar: URL?
    public let date: Date?
    public let blocks: [RichBlock]
}

public struct CommentPage: Sendable, Equatable {
    public var comments: [CommunityComment]
    public var total: Int
    public var start: Int
    public var pageSize: Int
    public var page: Int { pageSize > 0 ? start / pageSize + 1 : 1 }
    public var pageCount: Int { pageSize > 0 ? max(1, (total + pageSize - 1) / pageSize) : 1 }
}

public enum CommentParsers {
    /// The thread a shared-file or screenshot page shows, from its `InitializeCommentThread( … )` call.
    public static func thread(html: String) -> CommentThread? {
        guard let head = html.firstMatch(#"InitializeCommentThread\(\s*"([A-Za-z_]+)"\s*,\s*"[^"]*"\s*,\s*(.{0,2500})"#) else { return nil }
        let rest = head[2]
        guard let owner = rest.firstMatch(#""owner":"(\d+)""#)?[1],
              let feature = rest.firstMatch(#""feature":"?(-?\d+)"?"#)?[1] else { return nil }
        let feature2 = rest.firstMatch(#""feature2":"?(-?\d+)"?"#)?[1] ?? "-1"
        let total = rest.firstMatch(#""total_count":(\d+)"#).flatMap { Int($0[1]) } ?? 0
        var extended: String?
        if let raw = rest.firstMatch(#""extended_data":("(?:[^"\\]|\\.)*")"#)?[1],
           let s = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String { extended = s }
        return CommentThread(type: head[1], owner: owner, feature: feature, feature2: feature2, total: total, extendedData: extended)
    }

    /// The answer of `comment/<type>/render/…`.
    public static func page(json data: Data) -> CommentPage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["success"] as? Bool == true,
              let html = root["comments_html"] as? String else { return nil }
        func number(_ any: Any?) -> Int { (any as? Int) ?? (any as? String).flatMap(Int.init) ?? 0 }
        let comments = self.comments(html: html)
        return CommentPage(comments: comments, total: number(root["total_count"]), start: number(root["start"]),
                           pageSize: max(number(root["pagesize"]), 1))
    }

    public static func comments(html: String) -> [CommunityComment] {
        let base = URL(string: "https://steamcommunity.com/")
        return HTML.parse(html).all(class: "commentthread_comment").compactMap { c in
            guard let text = c.first(class: "commentthread_comment_text") else { return nil }
            let link = c.first(class: "commentthread_author_link")
            let stamp = c.all { $0.attr("data-timestamp") != nil }.first.flatMap { $0.attr("data-timestamp") }.flatMap(TimeInterval.init)
            let blocks = RichText.blocks(node: text, base: base)
            guard !blocks.isEmpty else { return nil }
            return CommunityComment(id: (c.attr("id") ?? "").replacingOccurrences(of: "comment_", with: ""),
                                    author: link?.plainText ?? "", authorURL: RichText.resolve(link?.attr("href") ?? "", base: base),
                                    avatar: avatar(c.first(class: "commentthread_comment_avatar"), base: base),
                                    date: stamp.map { Date(timeIntervalSince1970: $0) }, blocks: blocks)
        }
    }

    /// The picture inside the profile link; animated and framed avatars carry only a `srcset`.
    static func avatar(_ node: HTMLNode?, base: URL?) -> URL? {
        guard let link = node?.first(where: { $0.name == "a" && $0.attr("data-miniprofile") != nil }), let img = link.all(tag: "img").last else { return nil }
        let raw = img.attr("src") ?? img.attr("srcset")?.split(separator: " ").first.map(String.init)
        return raw.flatMap { RichText.resolve($0, base: base) }
    }

    /// The answer of `comment/<type>/post/…`: nil when Steam took the comment, else its reason.
    public static func postError(json data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Steam 没有正常回应。" }
        if root["success"] as? Bool == true { return nil }
        let reason = (root["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return reason ?? "Steam 没有接受这条留言。"
    }
}

public enum CommentClient {
    public static let pageSize = 10

    /// One page of a thread. Read-only; the render endpoint answers without a login.
    public static func fetch(_ thread: CommentThread, start: Int, count: Int = pageSize) async throws -> CommentPage {
        var request = URLRequest(url: thread.renderURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("start=\(start)&count=\(count)&l=schinese&feature2=\(thread.feature2)".utf8)
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let page = CommentParsers.page(json: data) else { throw URLError(.cannotParseResponse) }
        return page
    }

    /// Posts `text` as the signed-in user. `cookie` is the web session's Cookie header (steamLoginSecure …);
    /// the CSRF token is the `sessionid` cookie in it.
    public static func post(_ text: String, to thread: CommentThread, cookie: String) async throws {
        let session = cookie.split(separator: ";").compactMap { part -> String? in
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 && kv[0] == "sessionid" ? kv[1] : nil
        }.first
        guard let session else { throw PostFailure(reason: "网页登录还没有就绪，请稍后再试。") }
        var request = URLRequest(url: thread.postURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://steamcommunity.com", forHTTPHeaderField: "Origin")
        request.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        var fields = [("comment", text), ("count", "\(pageSize)"), ("sessionid", session), ("feature2", thread.feature2), ("json", "1")]
        if let extended = thread.extendedData { fields.append(("extended_data", extended)) }
        request.httpBody = Data(WebForm.encode(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PostFailure(reason: "Steam 没有正常回应。") }
        if let reason = CommentParsers.postError(json: data) { throw PostFailure(reason: reason) }
    }

    public struct PostFailure: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }
}

/// application/x-www-form-urlencoded bodies.
enum WebForm {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }
}
