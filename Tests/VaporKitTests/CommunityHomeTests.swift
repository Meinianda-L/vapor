import XCTest
@testable import VaporKit

final class CommunityHomeTests: XCTestCase {
    func testHomeCards() {
        let html = """
        <div class="apphub_Card modalContentLink interactable ugc" data-modal-content-url="https://steamcommunity.com/sharedfiles/filedetails/?id=11" id="apphub_Card_11" data-appid="1850570">
         <div class="apphub_CardContentType">DEATH STRANDING: DIRECTOR'S CUT: 截图</div>
         <img class="apphub_CardContentPreviewImage" src="https://images.steamusercontent.com/ugc/1/A/?imw=1024">
         <div class="apphub_CardRating rateUp"> 143 </div><div class="apphub_CardCommentCount">90</div>
         <div class="apphub_CardContentTitle ellipsis">&nbsp;</div>
         <div class="apphub_CardContentAppName"><a href="https://steamcommunity.com/app/1850570">DEATH STRANDING</a></div></div>
        <div class="apphub_Card interactable modalContentLink" data-modal-content-url="https://steamcommunity.com/sharedfiles/filedetails/?id=12" id="apphub_Card_12">
         <div class="apphub_CardContentType guide">暴力摩托: 指南</div>
         <div class="apphub_CardContentGuideTitle"><img src="https://images.steamusercontent.com/ugc/2/B/"> 汉化补丁</div>
         <div class="apphub_CardContentGuideDesc">说明&nbsp;</div>
         <div class="apphub_CardContentAppName"><a href="https://steamcommunity.com/app/4568550">暴力摩托</a></div></div>
        <div class="Broadcast_Card apphub_Card interactable"><a href="https://steamcommunity.com/broadcast/watch/765">
         <div class="apphub_CardContentType">Euro Truck Simulator 2: 实况直播</div>
         <img class="apphub_CardContentPreviewImage" src="https://steambroadcast.akamaized.net/t/">
         <div class="apphub_CardContentViewers ellipsis">4,694 名观众&nbsp;</div></a></div>
        <div class="apphub_Card"><div class="apphub_CardContentType">某游戏: 评测</div></div>
        """
        let cards = CommunityHomeParser.cards(html: html)
        XCTAssertEqual(cards.map(\.kind), [.screenshot, .guide, .broadcast])
        XCTAssertEqual(cards[0].appid, 1850570)
        XCTAssertEqual(cards[0].rating, "143")
        XCTAssertEqual(cards[0].comments, 90)
        XCTAssertEqual(cards[0].title, "")
        XCTAssertEqual(cards[1].title, "汉化补丁")
        XCTAssertEqual(cards[1].appid, 4568550)
        XCTAssertNotNil(cards[1].image)
        XCTAssertEqual(cards[2].viewers, "4,694 名观众")
        XCTAssertEqual(cards[2].url.path, "/broadcast/watch/765")
        let url = CommunityHomeClient.feed(.screenshots, recent: true, page: 2, anonymous: true).absoluteString
        XCTAssertTrue(url.contains("appHubSubSection=2") && url.contains("browsefilter=mostrecent") && url.contains("forceanon=1") && url.contains("p=2"))
    }

    func testDiscussionIndex() {
        let html = """
        <div class="discussions_forumlist"><div class="discussions_forum_row ">
         <div class="discussions_forumlist_linkoverlay"><a href="https://steamcommunity.com/discussions/forum/1/"><img src="x"></a></div>
         <div class="discussions_forumlist_topiccount"> 629,935 </div>
         <div class="discussions_forumlist_lastpost"><span data-timestamp="1794827483">17 分钟以前</span></div>
         <div class="discussions_forumlist_content"><div class="discussions_forumlist_forumname"> Help and Tips </div></div></div></div>
        <div class="forum_list_right"><a class="recent_game_discussion" href="https://steamcommunity.com/app/1840/discussions/">
         <div class="playerAvatar"><img src="https://avatars.example/a.jpg"></div>
         <div class="recent_game_discussion_name"> Source Filmmaker </div><div class="recent_game_discussion_count"> 53,484 个讨论串 </div></a></div>
        """
        let index = CommunityHomeParser.discussionIndex(html: html)
        XCTAssertEqual(index.forums.first?.name, "Help and Tips")
        XCTAssertEqual(index.forums.first?.topics, "629,935")
        XCTAssertEqual(index.forums.first?.lastPost, Date(timeIntervalSince1970: 1794827483))
        XCTAssertEqual(index.groups.first?.name, "Source Filmmaker")
        XCTAssertEqual(CommunityPage.page(for: index.groups[0].url), .discussions(appid: 1840, forum: nil, topic: nil))
        XCTAssertNil(CommunityPage.page(for: index.forums[0].url))
    }

    func testWorkshopFront() {
        let results = "<div class=\\\"workshopAppsRow\\\"><div class=\\\"app\\\" onClick=\\\"top.location.href='https://steamcommunity.com/app/866510/workshop/'\\\"><div class=\\\"appItem\\\"><div class=\\\"itemPreviewHolder\\\" style=\\\"background: url('https://images.steamusercontent.com/ugc/1/A/?imw=200') center\\\"></div></div><div class=\\\"appCover\\\"><img class=\\\"appLogo\\\" src=\\\"https://x/capsule.jpg\\\" alt=\\\"Engagement\\\"><div class=\\\"appNumItems\\\">16 项物品</div></div></div></div>"
        let json = "{\"success\":true,\"total_count\":3888,\"results_html\":\"\(results)\"}"
        let front = CommunityHomeParser.workshopFront(json: Data(json.utf8))
        XCTAssertEqual(front?.total, 3888)
        XCTAssertEqual(front?.apps.first?.appid, 866510)
        XCTAssertEqual(front?.apps.first?.name, "Engagement")
        XCTAssertEqual(front?.apps.first?.items, "16 项物品")
        XCTAssertNotNil(front?.apps.first?.preview)
        XCTAssertEqual(CommunityPage.page(for: front!.apps[0].url), .workshop(appid: 866510))
    }

    func testMarket() {
        let json = """
        {"success":true,"start":0,"pagesize":10,"total_count":35541,"results":[{"name":"热潮武器箱","hash_name":"Fever Case","sell_listings":253838,"sell_price":74,"sell_price_text":"¥ 5.00","app_name":"Counter-Strike 2","app_icon":"https://x/i.jpg","asset_description":{"appid":730,"icon_url":"abc","name_color":"b0c3d9","type":"普通级 武器箱","commodity":1}}]}
        """
        let page = MarketParser.page(json: Data(json.utf8))
        XCTAssertEqual(page?.total, 35541)
        let item = page?.items.first
        XCTAssertEqual(item?.appid, 730)
        XCTAssertEqual(item?.hashName, "Fever Case")
        XCTAssertEqual(item?.priceText, "¥ 5.00")
        XCTAssertEqual(item?.nameColor, "b0c3d9")
        XCTAssertEqual(item?.icon(size: 64)?.absoluteString, "https://community.akamai.steamstatic.com/economy/image/abc/64fx64f")
        XCTAssertTrue(item?.commodity == true)
        let price = MarketParser.price(json: Data(#"{"success":true,"lowest_price":"¥ 5.00","volume":"29,848","median_price":"¥ 4.98"}"#.utf8))
        XCTAssertEqual(price, MarketPrice(lowest: "¥ 5.00", median: "¥ 4.98", volume: "29,848"))
        XCTAssertNil(MarketParser.price(json: Data(#"{"success":false}"#.utf8)))
        XCTAssertTrue(MarketClient.search(query: "a b", appid: 730, start: 20, count: 20).absoluteString.contains("currency=23"))
        XCTAssertTrue(MarketClient.priceOverview(appid: 730, hashName: "AK-47 | Redline").absoluteString.contains("market_hash_name=AK-47"))
    }

    func testBlotter() {
        let html = """
        <div class="blotter_day"><div class="blotter_day_header">11 月 16 日</div>
         <div class="blotter_block"><div class="blotter_userstatus">
          <div class="blotter_author_block"><div class="playerAvatar"><a href="https://steamcommunity.com/profiles/765"><img src="https://avatars.example/a.jpg"></a></div>
           <a class="whiteLink" href="https://steamcommunity.com/profiles/765">Alice</a></div>
          <div class="blotter_screenshot">Alice 上传了截图 <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=99"><img src="https://images.steamusercontent.com/ugc/9/Z/"></a></div></div></div>
        </div>
        """
        let events = BlotterParser.events(html: html)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].author, "Alice")
        XCTAssertEqual(events[0].day, "11 月 16 日")
        XCTAssertEqual(events[0].link?.query, "id=99")
        XCTAssertNotNil(events[0].image)
        XCTAssertNotNil(events[0].avatar)
    }
}
