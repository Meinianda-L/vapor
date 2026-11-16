import Foundation

/// URLs and cached GETs for Steam's community pages. Nothing here writes to Steam.
public enum CommunityClient {
    public static let origin = "https://steamcommunity.com"

    // MARK: URLs

    public static func hub(_ appid: UInt32) -> URL { url("/app/\(appid)", ["l": "schinese"]) }

    /// Screenshots (`images` for artwork) browse page.
    public static func media(_ appid: UInt32, segment: String, recent: Bool, page: Int) -> URL {
        url("/app/\(appid)/\(segment)/", ["browsefilter": recent ? "mostrecent" : "trend", "p": "\(page)", "l": "schinese"])
    }

    public static func forum(_ base: URL, page: Int) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = (c.queryItems ?? []).filter { $0.name != "fp" && $0.name != "l" }
        if page > 1 { items.append(URLQueryItem(name: "fp", value: "\(page)")) }
        items.append(URLQueryItem(name: "l", value: "schinese"))
        c.queryItems = items
        return c.url ?? base
    }

    public static func defaultForum(_ appid: UInt32) -> URL { url("/app/\(appid)/discussions/", [:]) }

    public static func forumSearch(_ appid: UInt32, query: String, gidForum: String?, page: Int) -> URL {
        url("/app/\(appid)/discussions/search/", ["q": query, "gidforum": gidForum ?? "", "p": "\(page)", "l": "schinese"])
    }

    public static func thread(_ base: URL, page: Int) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.fragment = nil
        var items = (c.queryItems ?? []).filter { $0.name != "ctp" && $0.name != "l" }
        if page > 1 { items.append(URLQueryItem(name: "ctp", value: "\(page)")) }
        items.append(URLQueryItem(name: "l", value: "schinese"))
        c.queryItems = items
        return c.url ?? base
    }

    /// Workshop items (`section` readytouseitems) or guides (`guides`); `search` may be empty.
    public static func browse(_ appid: UInt32, section: String, sort: String, search: String, page: Int) -> URL {
        var q = ["appid": "\(appid)", "browsesort": sort, "section": section, "p": "\(page)", "l": "schinese"]
        if !search.isEmpty { q["searchtext"] = search }
        return url("/workshop/browse/", q)
    }

    public static func file(_ id: UInt64) -> URL { url("/sharedfiles/filedetails/", ["id": "\(id)", "l": "schinese"]) }

    public static func inventoryPage(_ steamID: String) -> URL { url("/profiles/\(steamID)/inventory/", ["l": "schinese"]) }

    public static func inventory(_ steamID: String, appid: UInt32, context: String, after: String?) -> URL {
        var q = ["l": "schinese", "count": "75"]
        if let after { q["start_assetid"] = after }
        return url("/inventory/\(steamID)/\(appid)/\(context)", q)
    }

    public static func rewards(_ appid: UInt32, cursor: String?) -> URL {
        var c = URLComponents(string: "https://api.steampowered.com/ILoyaltyRewardsService/QueryRewardItems/v1/")!
        var items = [URLQueryItem(name: "appids[0]", value: "\(appid)"), URLQueryItem(name: "count", value: "40"), URLQueryItem(name: "language", value: "schinese")]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        c.queryItems = items
        return c.url!
    }

    private static func url(_ path: String, _ query: [String: String]) -> URL {
        var c = URLComponents(string: origin)!
        c.path = path
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    // MARK: Fetching

    public struct HTTPError: Error { public let status: Int }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (at: Date, data: Data)] = [:]
        func get(_ key: String, ttl: TimeInterval) -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[key], Date().timeIntervalSince(e.at) < ttl else { return nil }
            return e.data
        }
        func put(_ key: String, _ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if entries.count > 80 { entries = entries.filter { Date().timeIntervalSince($0.value.at) < 60 } }
            if entries.count > 80 { entries.removeAll() }
            entries[key] = (Date(), data)
        }
    }
    private static let cache = Cache()

    public static func cached(_ url: URL, ttl: TimeInterval = 300) -> Data? { cache.get(url.absoluteString, ttl: ttl) }

    /// GET with a 20 s bound. `cookie` is a ready `Cookie` header value for pages that need the web session.
    public static func fetch(_ url: URL, cookie: String? = nil, ttl: TimeInterval = 300) async throws -> Data {
        let key = url.absoluteString + (cookie == nil ? "" : "#session")
        if let hit = cache.get(key, ttl: ttl) { return hit }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status) }
        cache.put(key, data)
        return data
    }

    public static func fetchString(_ url: URL, cookie: String? = nil, ttl: TimeInterval = 300) async throws -> String {
        String(decoding: try await fetch(url, cookie: cookie, ttl: ttl), as: UTF8.self)
    }
}
