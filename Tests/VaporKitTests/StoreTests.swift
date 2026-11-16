import XCTest
@testable import VaporKit

final class StoreTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testItemsKeepPricesArtAndReleaseWording() {
        let json = """
        {"metadata":{"total_matching_records":6128},"store_items":[
          {"item_type":0,"id":5175310,"success":1,"name":"我带过的最差一届","appid":5175310,"tagids":[1663,19],
           "reviews":{"summary_filtered":{"review_count":1200,"percent_positive":91,"review_score_label":"特别好评"}},
           "basic_info":{"short_description":"简介"},
           "assets":{"asset_url_format":"steam/apps/5175310/${FILENAME}?t=1","main_capsule":"capsule_616x353_schinese.jpg","header":"abc/header.jpg"},
           "release":{"steam_release_date":1794268873},
           "best_purchase_option":{"packageid":1791304,"final_price_in_cents":"1820","original_price_in_cents":"2800",
             "formatted_final_price":"¥18.20","formatted_original_price":"¥28.00","discount_pct":35,
             "active_discounts":[{"discount_end_date":1795456811}]},
           "screenshots":{"all_ages_screenshots":[{"filename":"steam/apps/5175310/ss_1.jpg?t=1"}]}},
          {"item_type":0,"id":1,"success":1,"name":"Deadlock","release":{"is_coming_soon":true,"coming_soon_display":"text_tba"}},
          {"item_type":1,"id":847489,"success":1,"name":"黑神话：悟空","included_appids":[2358720]},
          {"item_type":2,"id":28187,"success":15,"name":""}
        ]}
        """
        let items = SteamUI.parseItems(data(json))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(SteamUI.total(data(json)), 6128)

        let a = items[0]
        XCTAssertEqual(a.ref, .app(5175310))
        XCTAssertEqual(a.price?.final, "¥18.20")
        XCTAssertEqual(a.price?.original, "¥28.00")
        XCTAssertEqual(a.price?.discount, 35)
        XCTAssertEqual(a.price?.finalCents, 1820)
        XCTAssertEqual(a.price?.packageID, 1791304)
        XCTAssertEqual(a.price?.discountEnds, Date(timeIntervalSince1970: 1795456811))
        XCTAssertEqual(a.capsule?.absoluteString,
                       "https://shared.steamstatic.com/store_item_assets/steam/apps/5175310/capsule_616x353_schinese.jpg?t=1")
        XCTAssertEqual(a.header?.absoluteString, "https://shared.steamstatic.com/store_item_assets/steam/apps/5175310/abc/header.jpg?t=1")
        XCTAssertEqual(a.screenshots.count, 1)
        XCTAssertEqual(a.reviewLabel, "特别好评")
        XCTAssertEqual(a.reviewPercent, 91)
        XCTAssertEqual(a.tagIDs, [1663, 19])
        XCTAssertEqual(a.releaseText, "2026 年 11 月 10 日")

        XCTAssertTrue(items[1].comingSoon)
        XCTAssertEqual(items[1].releaseText, "待定")
        XCTAssertNil(items[1].price)

        let pkg = items[2]
        XCTAssertEqual(pkg.ref, SteamUI.StoreItemID(.package, 847489))
        XCTAssertEqual(pkg.appid, 2358720)
        XCTAssertEqual(pkg.header?.absoluteString, "https://shared.steamstatic.com/store_item_assets/steam/apps/2358720/header.jpg")
    }

    func testComingSoonDatesAreAsPreciseAsSteamShowsThem() {
        let q3 = Date(timeIntervalSince1970: 1803517200)   // 2027-02-24 in Shanghai
        XCTAssertEqual(SteamUI.releaseText(["coming_soon_display": "date_quarter"], date: q3, comingSoon: true), "2027 年第 1 季度")
        XCTAssertEqual(SteamUI.releaseText(["coming_soon_display": "date_month"], date: q3, comingSoon: true), "2027 年 2 月")
        XCTAssertEqual(SteamUI.releaseText(["coming_soon_display": "date_year"], date: q3, comingSoon: true), "2027 年")
        XCTAssertEqual(SteamUI.releaseText(["custom_release_date_message": "2027 年春"], date: q3, comingSoon: true), "2027 年春")
        XCTAssertEqual(SteamUI.releaseText([:], date: nil, comingSoon: true), "即将推出")
    }

    func testWishlistCartAndWallet() {
        let wish = SteamUI.parseWishlist(data(#"{"items":[{"appid":220200,"priority":2,"date_added":1781948167},{"appid":0}]}"#))
        XCTAssertEqual(wish, [SteamUI.WishlistEntry(appid: 220200, priority: 2, added: Date(timeIntervalSince1970: 1781948167))])

        let cart = SteamUI.parseCart(data("""
        {"cart":{"line_items":[
          {"line_item_id":"5551234567890123456","packageid":440408,"is_valid":true,"time_added":1790000000,
           "price_when_added":{"amount_in_cents":"29800","currency_code":23,"formatted_amount":"¥298.00"},"flags":{"is_gift":true}},
          {"line_item_id":"2","bundleid":28187,"is_valid":false}],
         "subtotal":{"amount_in_cents":"29800","formatted_amount":"¥298.00"},"is_valid":true}}
        """))
        XCTAssertEqual(cart.lines.count, 2)
        XCTAssertEqual(cart.lines[0].id, "5551234567890123456")
        XCTAssertEqual(cart.lines[0].item, SteamUI.StoreItemID(.package, 440408))
        XCTAssertEqual(cart.lines[0].price, "¥298.00")
        XCTAssertTrue(cart.lines[0].isGift)
        XCTAssertEqual(cart.lines[1].item, SteamUI.StoreItemID(.bundle, 28187))
        XCTAssertFalse(cart.lines[1].isValid)
        XCTAssertEqual(cart.subtotal, "¥298.00")
        XCTAssertTrue(SteamUI.parseCart(data(#"{"cart":{"line_items":[],"is_valid":true}}"#)).lines.isEmpty)

        let wallet = SteamUI.parseWallet(data(#"{"has_wallet":true,"user_country_code":"CN","balance":"12345","delayed_balance":"0","currency_code":23}"#))
        XCTAssertEqual(wallet.balance, "¥123.45")
        XCTAssertEqual(wallet.country, "CN")
        XCTAssertEqual(SteamUI.Wallet.format(cents: 1999, currency: 3), "19.99€")
        XCTAssertEqual(SteamUI.Wallet.format(cents: -500, currency: 1), "-$5.00")
        XCTAssertEqual(SteamUI.Wallet.format(cents: 120000, currency: 8), "¥ 1200")
        XCTAssertEqual(SteamUI.Wallet.format(cents: 100, currency: 999), "1.00")
    }

    func testQueryBodyCarriesFilters() {
        var q = SteamUI.StoreQuery(start: 24, count: 12, sort: .topSellers, tagIDs: [122], discountedOnly: true)
        q.releasedWithinDays = 30
        let body = q.body(now: Date(timeIntervalSince1970: 1_000_000))
        let query = body["query"] as? [String: Any]
        XCTAssertEqual(query?["start"] as? Int, 24)
        XCTAssertEqual(query?["count"] as? Int, 12)
        XCTAssertEqual(query?["sort"] as? Int, 10)
        let filters = query?["filters"] as? [String: Any]
        XCTAssertEqual((filters?["tagids_must_match"] as? [[String: [Int]]])?.first?["tagids"], [122])
        XCTAssertEqual((filters?["price_filters"] as? [String: Int])?["min_discount_percent"], 1)
        let range = filters?["release_date_filter"] as? [String: Int]
        XCTAssertEqual(range?["release_date_type"], 1)
        XCTAssertEqual(range?["start_date"], 1_000_000 - 30 * 86400)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testTags() {
        XCTAssertEqual(SteamUI.parseTags(data(#"{"tags":[{"tagid":492,"name":"独立"},{"tagid":19,"name":""}]}"#)),
                       [SteamUI.StoreTag(id: 492, name: "独立")])
    }

    func testPublicEndpointsFallback() {
        let featured = SteamUI.parseFeatured(data("""
        {"specials":{"items":[{"id":5175310,"type":0,"name":"我带过的最差一届","discount_percent":35,"original_price":2800,"final_price":1820,
          "currency":"CNY","large_capsule_image":"https://x/capsule.jpg","header_image":"https://x/header.jpg"},
          {"id":5175310,"type":0,"name":"我带过的最差一届","discount_percent":35,"original_price":2800,"final_price":1820,"currency":"CNY"}]},
         "coming_soon":{"items":[{"id":5492180,"type":0,"name":"Grand Space Game","original_price":null,"final_price":0,"currency":"CNY"}]}}
        """))
        XCTAssertEqual(featured["specials"]?.count, 1)
        XCTAssertEqual(featured["specials"]?.first?.price?.final, "¥18.20")
        XCTAssertEqual(featured["specials"]?.first?.price?.original, "¥28.00")
        XCTAssertNil(featured["coming_soon"]?.first?.price)
        XCTAssertEqual(featured["top_sellers"]?.count, 0)

        let search = SteamUI.parseStoreSearch(data("""
        {"total":2,"items":[{"type":"app","name":"艾尔登法环","id":1245620,"price":{"currency":"CNY","initial":29800,"final":14900}},
                            {"type":"sub","name":"x","id":9}]}
        """))
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(search[0].price?.final, "¥149.00")
        XCTAssertEqual(search[0].price?.discount, 50)
    }
}
