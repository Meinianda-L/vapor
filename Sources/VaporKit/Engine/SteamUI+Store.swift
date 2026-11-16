import Foundation

/// The Steam store, read through the signed-in client's own service connection (the one steamui's
/// pages use), so prices, wishlist and cart are the account's own and nothing goes through a web page.
///
/// steamui bundles the protobuf service namespaces (StoreBrowse, StoreQuery, Wishlist, AccountCart, …);
/// each is found by its own method names in webpack's module table, so module ids may move between
/// Steam updates. A namespace the module does not export (AccountCart) is reached by evaluating that
/// module's factory once more with the namespace exposed: it only defines classes and functions.
extension SteamUI {
    public static let storeLanguage = "schinese"

    // MARK: - Items

    public struct StoreItemID: Hashable, Sendable {
        public enum Kind: Int, Sendable { case app = 0, package = 1, bundle = 2 }
        public let kind: Kind
        public let id: UInt32
        public init(_ kind: Kind, _ id: UInt32) { self.kind = kind; self.id = id }
        public static func app(_ id: UInt32) -> StoreItemID { StoreItemID(.app, id) }

        var request: [String: UInt32] {
            switch kind {
            case .app: return ["appid": id]
            case .package: return ["packageid": id]
            case .bundle: return ["bundleid": id]
            }
        }
    }

    public struct StorePrice: Hashable, Sendable {
        public let final: String
        public let original: String
        public let discount: Int
        public let finalCents: Int64
        public let packageID: UInt32?
        public let bundleID: UInt32?
        public let discountEnds: Date?
    }

    public struct StoreItem: Hashable, Sendable, Identifiable {
        public let ref: StoreItemID
        public var id: StoreItemID { ref }
        public let name: String
        /// The app to open for this item: the item itself, or a package's or bundle's first app.
        public let appid: UInt32
        public let isFree: Bool
        public let comingSoon: Bool
        public let releaseDate: Date?
        /// Steam's own wording for an undated release ("待定"), or the release date as Steam would show it.
        public let releaseText: String
        public let summary: String
        public let tagIDs: [Int]
        public let reviewLabel: String
        public let reviewPercent: Int
        public let reviewCount: Int
        public let price: StorePrice?
        public let capsule: URL?       // 616×353
        public let header: URL?        // 460×215
        public let smallCapsule: URL?  // 231×87
        public let screenshots: [URL]
    }

    public struct StoreResults: Sendable {
        public let items: [StoreItem]
        public let total: Int
    }

    public enum StoreSort: Int, Sendable, CaseIterable {
        /// Values of steamui's EStoreQuerySort, identified by what the live service returns for each.
        case relevance = 0, topSellers = 10, trending = 11, newest = 20, reviews = 21, priceAscending = 40, priceDescending = 41
    }

    public struct StoreQuery: Hashable, Sendable {
        public var start = 0
        public var count = 24
        public var sort = StoreSort.topSellers
        public var tagIDs: [Int] = []
        public var discountedOnly = false
        public var freeOnly = false
        public var comingSoonOnly = false
        /// Released within this many days.
        public var releasedWithinDays: Int?
        public var includeDLC = false
        public var includeSoftware = false
        public init(start: Int = 0, count: Int = 24, sort: StoreSort = .topSellers, tagIDs: [Int] = [], discountedOnly: Bool = false,
                    freeOnly: Bool = false, comingSoonOnly: Bool = false, releasedWithinDays: Int? = nil) {
            self.start = start; self.count = count; self.sort = sort; self.tagIDs = tagIDs; self.discountedOnly = discountedOnly
            self.freeOnly = freeOnly; self.comingSoonOnly = comingSoonOnly; self.releasedWithinDays = releasedWithinDays
        }

        func body(now: Date = Date()) -> [String: Any] {
            var types: [String: Any] = ["include_games": true]
            if includeDLC { types["include_dlc"] = true }
            if includeSoftware { types["include_software"] = true }
            var filters: [String: Any] = ["type_filters": types]
            if !tagIDs.isEmpty { filters["tagids_must_match"] = [["tagids": tagIDs]] }
            if discountedOnly { filters["price_filters"] = ["min_discount_percent": 1] }
            if freeOnly { filters["price_filters"] = ["only_free_items": true] }
            if comingSoonOnly { filters["coming_soon_only"] = true }
            if let days = releasedWithinDays {
                let end = Int(now.timeIntervalSince1970)
                filters["released_only"] = true
                // release_date_type 1 limits results to items released between start_date and end_date.
                filters["release_date_filter"] = ["release_date_type": 1, "start_date": end - days * 86400, "end_date": end]
            }
            return ["query_name": "vapor", "query": ["start": start, "count": count, "sort": sort.rawValue, "filters": filters]]
        }
    }

    public struct StoreTag: Hashable, Sendable, Identifiable {
        public let id: Int
        public let name: String
    }

    static let itemData: [String: Any] = [
        "include_assets": true, "include_release": true, "include_reviews": true, "include_basic_info": true,
        "include_tag_count": 5, "include_best_purchase_option": true,
    ]

    /// Store items by id, in the order asked; ids Steam does not know are left out.
    public func storeItems(_ ids: [StoreItemID], screenshots: Bool = false) async throws -> [StoreItem] {
        guard !ids.isEmpty else { return [] }
        var data = Self.itemData
        if screenshots { data["include_screenshots"] = true }
        let body = try await storeCall("StoreBrowse", "GetItems", ["ids": ids.map(\.request), "context": [:] as [String: Any], "data_request": data])
        let items = Self.parseItems(body)
        let byID = Dictionary(items.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    public func storeQuery(_ query: StoreQuery, screenshots: Bool = false) async throws -> StoreResults {
        var body = query.body()
        var data = Self.itemData
        if screenshots { data["include_screenshots"] = true }
        body["context"] = [:] as [String: Any]
        body["data_request"] = data
        let reply = try await storeCall("StoreQuery", "Query", body)
        return StoreResults(items: Self.parseItems(reply), total: Self.total(reply))
    }

    /// What the store's search box suggests; Steam caps it at a few dozen matches.
    public func storeSearch(_ term: String, max: Int = 10) async throws -> [StoreItem] {
        let filters: [String: Any] = ["type_filters": ["include_apps": true, "include_games": true, "include_dlc": true, "include_software": true,
                                                       "include_packages": true, "include_bundles": true]]
        let body = try await storeCall("StoreQuery", "SearchSuggestions", [
            "query_name": "vapor", "search_term": term, "max_results": max, "use_spellcheck": true,
            "filters": filters, "context": [:] as [String: Any], "data_request": Self.itemData,
        ])
        return Self.parseItems(body)
    }

    /// The store's most used tags, named in the store language.
    public func storeTags() async throws -> [StoreTag] {
        Self.parseTags(try await storeCall("Store", "GetMostPopularTags", ["language": Self.storeLanguage]))
    }

    // MARK: - Wishlist

    public struct WishlistEntry: Hashable, Sendable {
        public let appid: UInt32
        public let priority: Int
        public let added: Date?
    }

    public func wishlist() async throws -> [WishlistEntry] {
        Self.parseWishlist(try await storeCall("Wishlist", "GetWishlist", ["steamid": "$steamid"]))
    }

    public func addToWishlist(_ appid: UInt32) async throws {
        _ = try await storeCall("Wishlist", "AddToWishlist", ["appid": appid])
    }

    public func removeFromWishlist(_ appid: UInt32) async throws {
        _ = try await storeCall("Wishlist", "RemoveFromWishlist", ["appid": appid])
    }

    // MARK: - Cart

    public struct CartLine: Hashable, Sendable, Identifiable {
        public let id: String          // line_item_id (fixed64, kept as text)
        public let item: StoreItemID
        public let price: String
        public let priceCents: Int64
        public let isGift: Bool
        public let isValid: Bool
        public let added: Date?
    }

    public struct Cart: Sendable {
        public let lines: [CartLine]
        public let subtotal: String
        public let subtotalCents: Int64
        public let isValid: Bool
        public static let empty = Cart(lines: [], subtotal: "", subtotalCents: 0, isValid: true)
    }

    public static let checkoutURL = URL(string: "https://checkout.steampowered.com/checkout/?accountcart=1")

    public func cart() async throws -> Cart {
        Self.parseCart(try await storeCall("AccountCart", "GetCart", ["user_country": "$country"]))
    }

    public func addToCart(_ item: StoreItemID) async throws {
        _ = try await storeCall("AccountCart", "AddItemsToCart", ["user_country": "$country", "items": [item.request]])
    }

    public func removeFromCart(_ lineID: String) async throws {
        _ = try await storeCall("AccountCart", "RemoveItemFromCart", ["line_item_id": lineID, "user_country": "$country"])
    }

    // MARK: - Account

    public struct Wallet: Sendable {
        public let hasWallet: Bool
        public let balanceCents: Int64
        public let pendingCents: Int64
        public let currency: Int
        public let country: String
        public let lastTransaction: Date?
        public var balance: String { Self.format(cents: balanceCents, currency: currency) }
        public var pending: String { Self.format(cents: pendingCents, currency: currency) }

        /// ECurrencyCode → how Steam prints that currency. Unknown codes get the bare amount.
        public static func format(cents: Int64, currency: Int) -> String {
            let symbols: [Int: (String, Bool)] = [1: ("$", true), 2: ("£", true), 3: ("€", false), 5: (" ₽", false), 7: ("R$ ", true),
                                                   8: ("¥ ", true), 20: ("CDN$ ", true), 21: ("A$ ", true), 23: ("¥", true),
                                                   24: ("₹ ", true), 29: ("HK$ ", true), 30: ("NT$ ", true)]
            let v = abs(cents)
            let digits = currency == 8 ? "\(v / 100)" : String(format: "%lld.%02lld", v / 100, v % 100)
            let sign = cents < 0 ? "-" : ""
            guard let (symbol, before) = symbols[currency] else { return sign + digits }
            return before ? sign + symbol + digits : sign + digits + symbol
        }
    }

    public func wallet() async throws -> Wallet {
        Self.parseWallet(try await storeCall("UserAccount", "GetClientWalletDetails", [:]))
    }

    // MARK: - Transport

    /// One service method over the client's connection. `"$steamid"` and `"$country"` in the body, and an
    /// empty `context`, are filled in by the page with the signed-in account's values.
    func storeCall(_ service: String, _ method: String, _ body: [String: Any]) async throws -> Data {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let args = String(decoding: try JSONSerialization.data(withJSONObject: [service, method]), as: UTF8.self)
        return try await evaluate("\(Self.storeKit)\nreturn await window.__vaporStore.call(...\(args), \(json));")
    }

    static let storeKitVersion = 1

    static let storeKit = #"""
    if (window.__vaporStore?.version !== \#(storeKitVersion)) window.__vaporStore = (() => {
      let req = null;
      const services = {};
      const service = name => {
        if (services[name]) return services[name];
        if (!req && window.webpackChunksteamui) window.webpackChunksteamui.push([[Symbol('vapor-store')], {}, r => { req = r; }]);
        if (!req) throw new Error('steamui is still loading');
        const tag = `SendMsg("${name}.`;
        const id = Object.keys(req.m).find(id => String(req.m[id]).includes(tag));
        if (!id) throw new Error(`no ${name} service`);
        const has = v => !!v && typeof v === 'object' && Object.values(v).some(f => typeof f === 'function' && String(f).includes(tag));
        let svc = Object.values(req(id)).find(has);
        if (!svc) {
          // `var X;(Y=>{function …SendMsg("Name.…` is how the namespace is declared; expose X on the exports.
          const src = String(req.m[id]);
          const local = [...src.slice(0, src.indexOf(tag)).matchAll(/var (\w+);\(\w+=>\{/g)].pop()?.[1];
          const exp = src.match(/^\(\w+,(\w+),\w+\)=>\{/)?.[1];
          if (local && exp && src.endsWith('}')) {
            const out = {};
            new Function(`return ${src.slice(0, -1)};${exp}.__vaporService=${local};}`)()({}, out, req);
            svc = out.__vaporService;
          }
        }
        if (!has(svc)) throw new Error(`no ${name} service`);
        return (services[name] = svc);
      };
      const transport = () => {
        const cm = window.App?.m_cm;
        if (!cm?.m_bLoggedOn || !cm.m_ServiceTransport) throw new Error('Steam is not signed in');
        return cm.m_ServiceTransport;
      };
      const send = async (name, method, body) => {
        const fn = service(name)[method];
        if (typeof fn !== 'function') throw new Error(`no ${name}.${method}`);
        let timer;
        const timeout = new Promise((_, no) => { timer = setTimeout(() => no(new Error(`${name}.${method} timed out`)), 15000); });
        try {
          const r = await Promise.race([fn(transport(), body), timeout]);
          const e = r.GetEResult();
          if (e !== 1) throw new Error(`${name}.${method}: EResult ${e}`);
          return r.Body().toObject();
        } finally { clearTimeout(timer); }
      };
      let country = null;
      const userCountry = async () => {
        if (country) return country;
        const w = await send('UserAccount', 'GetClientWalletDetails', {}).catch(() => null);
        country = w?.user_country_code || (await SteamClient.User.GetIPCountry?.().catch?.(() => '')) || '';
        return country;
      };
      return {
        version: \#(storeKitVersion),
        async call(name, method, body) {
          const steamid = window.App?.m_cm?.m_steamid?.ConvertTo64BitString?.();
          for (const [k, v] of Object.entries(body)) {
            if (v === '$steamid') body[k] = steamid;
            if (v === '$country') body[k] = await userCountry();
          }
          if (body.context && !Object.keys(body.context).length)
            body.context = { language: '\#(storeLanguage)', country_code: await userCountry(), steam_realm: 1 };
          return send(name, method, body);
        },
      };
    })();
    """#
}

// MARK: - Parsing (pure, from the services' toObject() JSON)

extension SteamUI {
    static let assetBase = "https://shared.steamstatic.com/store_item_assets/"

    private static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// int64/uint64 fields arrive as strings, the rest as numbers.
    static func int(_ any: Any?) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) ?? 0 }
        return 0
    }

    static func date(_ any: Any?) -> Date? {
        let t = int(any)
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }

    static func parseItems(_ data: Data) -> [StoreItem] {
        (object(data)["store_items"] as? [[String: Any]] ?? []).compactMap(item)
    }

    static func total(_ data: Data) -> Int {
        Int(int((object(data)["metadata"] as? [String: Any])?["total_matching_records"]))
    }

    static func item(_ d: [String: Any]) -> StoreItem? {
        guard int(d["success"]) == 1, let kind = StoreItemID.Kind(rawValue: Int(int(d["item_type"]))) else { return nil }
        let id = UInt32(truncatingIfNeeded: int(d["id"]))
        let name = d["name"] as? String ?? ""
        guard id > 0, !name.isEmpty else { return nil }
        let included = (d["included_appids"] as? [Any] ?? []).map { UInt32(truncatingIfNeeded: int($0)) }
        let appid = kind == .app ? id : (UInt32(truncatingIfNeeded: int(d["appid"])) != 0 ? UInt32(truncatingIfNeeded: int(d["appid"])) : included.first ?? 0)

        let assets = d["assets"] as? [String: Any] ?? [:]
        let format = assets["asset_url_format"] as? String
        func asset(_ key: String) -> URL? {
            guard let file = assets[key] as? String, !file.isEmpty else { return nil }
            if let format { return URL(string: assetBase + format.replacingOccurrences(of: "${FILENAME}", with: file)) }
            return nil
        }
        // Packages and bundles carry no art of their own; their first app's standard files stand in.
        func fallback(_ file: String) -> URL? { appid > 0 ? URL(string: "\(assetBase)steam/apps/\(appid)/\(file)") : nil }

        let release = d["release"] as? [String: Any] ?? [:]
        let comingSoon = release["is_coming_soon"] as? Bool ?? false
        let releaseDate = date(release["steam_release_date"]) ?? date(release["original_release_date"])
        let reviews = (d["reviews"] as? [String: Any])?["summary_filtered"] as? [String: Any]
        let basic = d["basic_info"] as? [String: Any]
        let shots = ((d["screenshots"] as? [String: Any])?["all_ages_screenshots"] as? [[String: Any]] ?? [])
            .compactMap { ($0["filename"] as? String).flatMap { URL(string: assetBase + $0) } }

        return StoreItem(
            ref: StoreItemID(kind, id), name: name, appid: appid, isFree: d["is_free"] as? Bool ?? false,
            comingSoon: comingSoon, releaseDate: releaseDate,
            releaseText: releaseText(release, date: releaseDate, comingSoon: comingSoon),
            summary: basic?["short_description"] as? String ?? "",
            tagIDs: (d["tagids"] as? [Any] ?? []).map { Int(int($0)) },
            reviewLabel: reviews?["review_score_label"] as? String ?? "",
            reviewPercent: Int(int(reviews?["percent_positive"])), reviewCount: Int(int(reviews?["review_count"])),
            price: price(d["best_purchase_option"] as? [String: Any]),
            capsule: asset("main_capsule") ?? fallback("capsule_616x353.jpg"),
            header: asset("header") ?? fallback("header.jpg"),
            smallCapsule: asset("small_capsule") ?? fallback("capsule_231x87.jpg"),
            screenshots: shots)
    }

    static func price(_ p: [String: Any]?) -> StorePrice? {
        guard let p, let final = p["formatted_final_price"] as? String, !final.isEmpty else { return nil }
        let ends = (p["active_discounts"] as? [[String: Any]] ?? []).compactMap { date($0["discount_end_date"]) }.min()
        let pkg = UInt32(truncatingIfNeeded: int(p["packageid"])), bundle = UInt32(truncatingIfNeeded: int(p["bundleid"]))
        let hidePct = p["hide_discount_pct_for_compliance"] as? Bool ?? false
        return StorePrice(final: final, original: p["formatted_original_price"] as? String ?? "",
                          discount: hidePct ? 0 : Int(int(p["discount_pct"])), finalCents: int(p["final_price_in_cents"]),
                          packageID: pkg == 0 ? nil : pkg, bundleID: bundle == 0 ? nil : bundle, discountEnds: ends)
    }

    /// How Steam labels a release: undated ones by their display mode, dated ones as precisely as the
    /// publisher allows (a quarter or a year for coming-soon items).
    static func releaseText(_ r: [String: Any], date: Date?, comingSoon: Bool) -> String {
        if let custom = r["custom_release_date_message"] as? String, !custom.isEmpty { return custom }
        let mode = r["coming_soon_display"] as? String ?? ""
        if mode == "text_tba" { return "待定" }
        if mode == "text_comingsoon" { return "即将推出" }
        guard let date else { return comingSoon ? "即将推出" : "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        switch mode {
        case "date_year": return "\(y) 年"
        case "date_quarter": return "\(y) 年第 \((m - 1) / 3 + 1) 季度"
        case "date_month": return "\(y) 年 \(m) 月"
        default: return "\(y) 年 \(m) 月 \(d) 日"
        }
    }

    static func parseTags(_ data: Data) -> [StoreTag] {
        (object(data)["tags"] as? [[String: Any]] ?? []).compactMap { t in
            let id = Int(int(t["tagid"]))
            guard id > 0, let name = t["name"] as? String, !name.isEmpty else { return nil }
            return StoreTag(id: id, name: name)
        }
    }

    static func parseWishlist(_ data: Data) -> [WishlistEntry] {
        (object(data)["items"] as? [[String: Any]] ?? []).compactMap { w in
            let appid = UInt32(truncatingIfNeeded: int(w["appid"]))
            return appid == 0 ? nil : WishlistEntry(appid: appid, priority: Int(int(w["priority"])), added: date(w["date_added"]))
        }
    }

    static func parseCart(_ data: Data) -> Cart {
        guard let cart = object(data)["cart"] as? [String: Any] else { return .empty }
        let lines: [CartLine] = (cart["line_items"] as? [[String: Any]] ?? []).compactMap { l in
            let pkg = UInt32(truncatingIfNeeded: int(l["packageid"])), bundle = UInt32(truncatingIfNeeded: int(l["bundleid"]))
            guard let id = (l["line_item_id"] as? String) ?? (l["line_item_id"] as? NSNumber)?.stringValue, pkg != 0 || bundle != 0 else { return nil }
            let price = l["price_when_added"] as? [String: Any]
            return CartLine(id: id, item: pkg != 0 ? StoreItemID(.package, pkg) : StoreItemID(.bundle, bundle),
                            price: price?["formatted_amount"] as? String ?? "", priceCents: int(price?["amount_in_cents"]),
                            isGift: (l["flags"] as? [String: Any])?["is_gift"] as? Bool ?? false,
                            isValid: l["is_valid"] as? Bool ?? true, added: date(l["time_added"]))
        }
        let subtotal = cart["subtotal"] as? [String: Any]
        return Cart(lines: lines, subtotal: subtotal?["formatted_amount"] as? String ?? "", subtotalCents: int(subtotal?["amount_in_cents"]),
                    isValid: cart["is_valid"] as? Bool ?? true)
    }

    static func parseWallet(_ data: Data) -> Wallet {
        let w = object(data)
        return Wallet(hasWallet: w["has_wallet"] as? Bool ?? false, balanceCents: int(w["balance"]), pendingCents: int(w["delayed_balance"]),
                      currency: Int(int(w["currency_code"])), country: w["user_country_code"] as? String ?? "",
                      lastTransaction: date(w["time_most_recent_txn"]))
    }
}

// MARK: - Public store endpoints (when the client is not there)

extension SteamUI {
    /// store.steampowered.com/api/featuredcategories: the store front's lists without a signed-in client.
    public static func parseFeatured(_ data: Data) -> [String: [StoreItem]] {
        let root = object(data)
        var out: [String: [StoreItem]] = [:]
        for key in ["specials", "top_sellers", "new_releases", "coming_soon"] {
            let items = ((root[key] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap(featuredItem)
            var seen = Set<StoreItemID>()
            out[key] = items.filter { seen.insert($0.ref).inserted }
        }
        return out
    }

    private static func featuredItem(_ d: [String: Any]) -> StoreItem? {
        let id = UInt32(truncatingIfNeeded: int(d["id"]))
        guard id > 0, let name = d["name"] as? String, !name.isEmpty, int(d["type"]) == 0 else { return nil }
        let currency = d["currency"] as? String ?? ""
        func money(_ cents: Int64) -> String { currency == "CNY" ? String(format: "¥%lld.%02lld", cents / 100, cents % 100) : String(format: "%lld.%02lld", cents / 100, cents % 100) }
        let final = int(d["final_price"]), original = int(d["original_price"])
        let discount = Int(int(d["discount_percent"]))
        let price: StorePrice? = d["original_price"] is NSNull || d["original_price"] == nil ? nil
            : StorePrice(final: final == 0 ? "免费" : money(final), original: discount > 0 ? money(original) : "", discount: discount,
                         finalCents: final, packageID: nil, bundleID: nil, discountEnds: date(d["discount_expiration"]))
        let url = { (k: String) in (d[k] as? String).flatMap(URL.init(string:)) }
        return StoreItem(ref: .app(id), name: name, appid: id, isFree: price != nil && final == 0, comingSoon: false, releaseDate: nil,
                         releaseText: "", summary: "", tagIDs: [], reviewLabel: "", reviewPercent: 0, reviewCount: 0, price: price,
                         capsule: url("large_capsule_image"), header: url("header_image"), smallCapsule: url("small_capsule_image"), screenshots: [])
    }

    /// store.steampowered.com/api/storesearch.
    public static func parseStoreSearch(_ data: Data) -> [StoreItem] {
        (object(data)["items"] as? [[String: Any]] ?? []).compactMap { d in
            let id = UInt32(truncatingIfNeeded: int(d["id"]))
            guard id > 0, let name = d["name"] as? String, !name.isEmpty, (d["type"] as? String ?? "app") == "app" else { return nil }
            let p = d["price"] as? [String: Any]
            let price: StorePrice? = p.map { p in
                let final = int(p["final"]), initial = int(p["initial"])
                let f = { (c: Int64) in (p["currency"] as? String == "CNY" ? "¥" : "") + String(format: "%lld.%02lld", c / 100, c % 100) }
                return StorePrice(final: f(final), original: initial > final ? f(initial) : "",
                                  discount: initial > final && initial > 0 ? Int((100 * (initial - final) + initial / 2) / initial) : 0,
                                  finalCents: final, packageID: nil, bundleID: nil, discountEnds: nil)
            }
            return StoreItem(ref: .app(id), name: name, appid: id, isFree: p == nil, comingSoon: false, releaseDate: nil, releaseText: "",
                             summary: "", tagIDs: [], reviewLabel: "", reviewPercent: 0, reviewCount: 0, price: price,
                             capsule: URL(string: "\(assetBase)steam/apps/\(id)/capsule_616x353.jpg"),
                             header: URL(string: "\(assetBase)steam/apps/\(id)/header.jpg"),
                             smallCapsule: (d["tiny_image"] as? String).flatMap(URL.init(string:)), screenshots: [])
        }
    }
}
