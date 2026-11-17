import Foundation

// Steam Community Market, read-only: popular and searched listings, and an item's price summary.

public struct MarketItem: Identifiable, Sendable, Equatable {
    public var id: String { "\(appid)/\(hashName)" }
    public let appid: UInt32
    public let hashName: String
    public let name: String
    public let type: String
    public let appName: String
    public let appIcon: URL?
    public let iconKey: String?
    /// `RRGGBB` of the item's rarity colour, when Steam gives one.
    public let nameColor: String?
    public let sellListings: Int
    /// Lowest ask in the currency of the request (CNY when signed in, USD for anonymous search).
    public let priceText: String
    public let commodity: Bool

    public func icon(size: Int = 96) -> URL? { iconKey.flatMap { MarketClient.image($0, size: size) } }
}

public struct MarketPage: Sendable, Equatable {
    public var items: [MarketItem]
    public var total: Int
    public var start: Int
}

public struct MarketPrice: Sendable, Equatable {
    public let lowest: String?
    public let median: String?
    public let volume: String?
}

public enum MarketClient {
    public static let cny = 23

    public struct Game: Identifiable, Sendable, Hashable {
        public var id: UInt32 { appid }
        public let appid: UInt32
        public let name: String
    }

    /// The games Steam's market front lists first; the full list is thousands of apps long.
    public static let games = [Game(appid: 730, name: "Counter-Strike 2"), Game(appid: 570, name: "Dota 2"), Game(appid: 440, name: "Team Fortress 2"),
                               Game(appid: 578080, name: "PUBG: BATTLEGROUNDS"), Game(appid: 252490, name: "Rust"), Game(appid: 753, name: "Steam")]

    public static func search(query: String, appid: UInt32?, start: Int, count: Int) -> URL {
        var c = URLComponents(string: "https://steamcommunity.com/market/search/render/")!
        var items = [URLQueryItem(name: "norender", value: "1"), URLQueryItem(name: "query", value: query), URLQueryItem(name: "start", value: "\(start)"),
                     URLQueryItem(name: "count", value: "\(count)"), URLQueryItem(name: "search_descriptions", value: "0"),
                     URLQueryItem(name: "sort_column", value: "popular"), URLQueryItem(name: "sort_dir", value: "desc"),
                     URLQueryItem(name: "currency", value: "\(cny)"), URLQueryItem(name: "l", value: "schinese")]
        if let appid { items.append(URLQueryItem(name: "appid", value: "\(appid)")) }
        c.queryItems = items
        return c.url!
    }

    public static func priceOverview(appid: UInt32, hashName: String) -> URL {
        var c = URLComponents(string: "https://steamcommunity.com/market/priceoverview/")!
        c.queryItems = [URLQueryItem(name: "appid", value: "\(appid)"), URLQueryItem(name: "currency", value: "\(cny)"),
                        URLQueryItem(name: "market_hash_name", value: hashName)]
        return c.url!
    }

    /// The item's page on the web; Vapor only links to it for the order book Steam no longer serves as JSON.
    public static func listingPage(appid: UInt32, hashName: String) -> URL? {
        var c = URLComponents(string: "https://steamcommunity.com/")
        c?.percentEncodedPath = "/market/listings/\(appid)/" + (hashName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? hashName)
        c?.queryItems = [URLQueryItem(name: "l", value: "schinese")]
        return c?.url
    }

    public static func image(_ icon: String, size: Int = 96) -> URL? {
        URL(string: "https://community.akamai.steamstatic.com/economy/image/\(icon)/\(size)fx\(size)f")
    }
}

public enum MarketParser {
    public static func page(json data: Data) -> MarketPage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["success"] as? Bool == true,
              let results = obj["results"] as? [[String: Any]] else { return nil }
        let items: [MarketItem] = results.compactMap { r in
            guard let hash = r["hash_name"] as? String else { return nil }
            let d = r["asset_description"] as? [String: Any] ?? [:]
            guard let appid = (d["appid"] as? Int).flatMap(UInt32.init(exactly:)) else { return nil }
            let color = (d["name_color"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return MarketItem(appid: appid, hashName: hash, name: r["name"] as? String ?? hash, type: d["type"] as? String ?? "",
                              appName: r["app_name"] as? String ?? "", appIcon: (r["app_icon"] as? String).flatMap(URL.init(string:)),
                              iconKey: d["icon_url"] as? String, nameColor: color,
                              sellListings: r["sell_listings"] as? Int ?? 0, priceText: r["sell_price_text"] as? String ?? "",
                              commodity: (d["commodity"] as? Int) == 1)
        }
        return MarketPage(items: items, total: obj["total_count"] as? Int ?? items.count, start: obj["start"] as? Int ?? 0)
    }

    public static func price(json data: Data) -> MarketPrice? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["success"] as? Bool == true else { return nil }
        return MarketPrice(lowest: obj["lowest_price"] as? String, median: obj["median_price"] as? String, volume: obj["volume"] as? String)
    }
}
