import XCTest
@testable import VaporKit

final class CommunityTests: XCTestCase {
    func testHTMLTreeSurvivesUnclosedItemsAndEntities() {
        let root = HTML.parse("<ul><li>a &amp; b<li>c</ul><script>if (a<b) {}</script><p class='x y'>t&#39;s&nbsp;ok</p><br><!-- c -->")
        XCTAssertEqual(root.first(tag: "ul")?.all(tag: "li").map(\.plainText), ["a & b", "c"])
        XCTAssertEqual(root.first(class: "y")?.plainText, "t's ok")
        XCTAssertNil(root.first(tag: "script")?.children.first)
    }

    func testRichTextQuoteListImageAndLinkFilter() {
        let html = """
        <div class="bb_h1">Title</div>Hello <b>bold</b><br>line two
        <blockquote class="bb_blockquote with_author"><div class="bb_quoteauthor">引用自 <b>Bob</b>:</div>quoted</blockquote>
        <ul class="bb_ul"><li>one</li><li>two</li></ul>
        <a href="https://steamcommunity.com/linkfilter/?u=https%3A%2F%2Fexample.com%2Fx">out</a>
        <a class="modalContentLink" href="https://steamcommunity.com/sharedfiles/filedetails/?id=1"><img src="//cdn.example.com/a.png"></a>
        """
        let blocks = RichText.blocks(html: html)
        XCTAssertEqual(blocks.first, .heading("Title", level: 1))
        guard case .paragraph(let spans) = blocks[1] else { return XCTFail("paragraph expected") }
        XCTAssertEqual(spans.map(\.text).joined(), "Hello bold\nline two")
        XCTAssertTrue(spans.contains { $0.bold && $0.text == "bold" })
        guard case .quote(let author, let inner) = blocks[2] else { return XCTFail("quote expected") }
        XCTAssertEqual(author, "引用自 Bob")
        XCTAssertEqual(inner.first?.plain, "quoted")
        XCTAssertEqual(blocks[3], .list([[RichSpan("one")], [RichSpan("two")]], ordered: false))
        guard case .paragraph(let link) = blocks[4] else { return XCTFail() }
        XCTAssertEqual(link.first?.link, URL(string: "https://example.com/x"))
        XCTAssertEqual(blocks.last, .image(URL(string: "https://cdn.example.com/a.png")!))
    }

    func testPageMapper() {
        func page(_ s: String) -> CommunityPage? { CommunityPage.page(for: URL(string: s)!) }
        XCTAssertEqual(page("https://steamcommunity.com/app/730"), .hub(appid: 730, tab: .all))
        XCTAssertEqual(page("https://steamcommunity.com/app/730/screenshots/"), .hub(appid: 730, tab: .screenshots))
        XCTAssertEqual(page("https://steamcommunity.com/app/730/discussions/"), .discussions(appid: 730, forum: nil, topic: nil))
        let forum = URL(string: "https://steamcommunity.com/app/730/discussions/1/")!
        XCTAssertEqual(page(forum.absoluteString), .discussions(appid: 730, forum: forum, topic: nil))
        let topic = URL(string: "https://steamcommunity.com/app/730/discussions/0/563673525951620403/")!
        XCTAssertEqual(page(topic.absoluteString), .discussions(appid: 730, forum: nil, topic: topic))
        XCTAssertEqual(page("https://steamcommunity.com/app/620/guides/"), .guides(appid: 620))
        XCTAssertEqual(page("https://steamcommunity.com/app/620/workshop/"), .workshop(appid: 620))
        XCTAssertEqual(page("https://steamcommunity.com/workshop/browse/?appid=620&browsesort=trend"), .workshop(appid: 620))
        XCTAssertEqual(page("https://steamcommunity.com/sharedfiles/filedetails/?id=3005262277"), .sharedFile(id: 3005262277))
        XCTAssertEqual(page("steam://url/CommunityFilePage/42"), .sharedFile(id: 42))
        XCTAssertEqual(page("https://steamcommunity.com/profiles/76561198735163279/inventory/#753_6"), .inventory(steamID: "76561198735163279", appid: 753))
        XCTAssertEqual(page("https://store.steampowered.com/points/shop/app/620"), .pointsShop(appid: 620))
        XCTAssertNil(page("https://steamcommunity.com/profiles/76561198735163279"))
        XCTAssertNil(page("https://store.steampowered.com/app/620"))
    }

    func testForumListing() {
        let html = """
        <div class="forumselector"><select><option value="https://steamcommunity.com/app/620/discussions/0/" selected>综合讨论</option>
        <option value="https://steamcommunity.com/app/620/discussions/1/">Workshop</option></select></div>
        <div class="forum_topic  unread sticky" id="forum_General_1_9" data-gidforumtopic="9" data-tooltip-forum="&lt;b&gt;x&lt;/b&gt;">
          <a class="forum_topic_overlay" href="https://steamcommunity.com/app/620/discussions/0/9/"></a>
          <div class="forum_topic_details"><div class="forum_topic_reply_count"><img src="x.png"> 2,268</div>
          <div class="forum_topic_lastpost" data-timestamp="1794000660">11 月 6 日</div></div>
          <div class="forum_topic_name "><span class="forum_topic_label sticky_label">置顶：</span> Coop hub </div>
          <div class="forum_topic_op"> Nicolas </div></div>
        <script>InitializeForum( "General_1", {"owner":"1","gidforum":"864943227216351454","total_count":1619,"start":15,"pagesize":15}, 'x' );</script>
        """
        let f = CommunityParsers.forum(html: html)
        XCTAssertEqual(f.forums.map(\.name), ["综合讨论", "Workshop"])
        XCTAssertEqual(f.forumName, "综合讨论")
        let t = try! XCTUnwrap(f.topics.first)
        XCTAssertEqual(t.title, "Coop hub")
        XCTAssertEqual(t.author, "Nicolas")
        XCTAssertEqual(t.replies, 2268)
        XCTAssertTrue(t.pinned)
        XCTAssertFalse(t.locked)
        XCTAssertEqual(t.lastPost, Date(timeIntervalSince1970: 1794000660))
        XCTAssertEqual([f.start, f.total, f.pageSize, f.page, f.pageCount], [15, 1619, 15, 2, 108])
        XCTAssertEqual(f.gidForum, "864943227216351454")
    }

    func testThreadParsing() {
        let html = """
        <div class="forum_breadcrumbs"><a href="https://steamcommunity.com/app/730">CS2</a> &gt; <a href="https://steamcommunity.com/app/730/discussions/0/">综合讨论</a></div>
        <div class="forum_op" id="forum_op_55"><div class="forum_op_avatar"><img src="https://x/frame.png"><a href="u"><img src="https://avatars.akamai.steamstatic.com/a.jpg"></a></div>
        <a class="forum_op_author" href="https://steamcommunity.com/profiles/1">OP</a><div class="date" data-timestamp="100">x</div>
        <div class="topic"> Trade </div><div class="content">hello<br>world</div></div>
        <div class="commentthread_comment" id="comment_77"><div class="commentthread_comment_avatar"><a><img src="https://avatars.akamai.steamstatic.com/b.jpg"></a></div>
        <a class="commentthread_author_link" href="https://steamcommunity.com/id/v"><bdi>Bob</bdi></a><div class="commentthread_comment_timestamp" data-timestamp="200"></div>
        <div class="commentthread_comment_text">reply</div><div class="forum_comment_permlink"><a href="#c77">#1</a></div></div>
        <script>InitializeCommentThread( "ForumTopic", "k", {"total_count":31,"start":15,"pagesize":15} );</script>
        """
        let t = try! XCTUnwrap(CommunityParsers.thread(html: html))
        XCTAssertEqual(t.title, "Trade")
        XCTAssertEqual(t.forumName, "综合讨论")
        XCTAssertEqual(t.opening?.avatar?.absoluteString, "https://avatars.akamai.steamstatic.com/a.jpg")
        XCTAssertEqual(t.opening?.blocks.first?.plain, "hello\nworld")
        XCTAssertEqual(t.replies.first?.author, "Bob")
        XCTAssertEqual(t.replies.first?.number, "#1")
        XCTAssertEqual([t.total, t.page, t.pageCount], [31, 2, 3])
    }

    func testHubCards() {
        let html = """
        <div class="apphub_AppName">Portal 2</div>
        <a class="apphub_sectionTab" href="https://steamcommunity.com/app/620/guides/"><span>指南</span></a>
        <a class="apphub_sectionTab" href="https://steamcommunity.com/app/620/workshop/"><span>创意工坊</span></a>
        <div class="apphub_Card interactable modalContentLink" id="apphub_Card_5" data-modal-content-url="https://steamcommunity.com/sharedfiles/filedetails/?id=5">
          <div class="apphub_CardContentMain"><div class="apphub_CardContentType guide">指南</div>
          <div class="apphub_CardContentGuideTitle"><img class="apphub_CardContentGuideImage" src="https://i/g.jpg"> Editor </div>
          <div class="apphub_CardContentGuideDesc">desc</div></div>
          <div class="apphub_CardContentAuthorName">Ann</div></div>
        <div class="apphub_Card" data-modal-content-url="https://steamcommunity.com/id/x/recommended/620/"></div>
        """
        let hub = CommunityParsers.hub(html: html, appid: 620)
        XCTAssertEqual(hub.appName, "Portal 2")
        XCTAssertEqual(hub.tabs, [.all, .guides, .workshop])
        XCTAssertEqual(hub.cards.count, 1)
        XCTAssertEqual(hub.cards[0].kind, .guide)
        XCTAssertEqual(hub.cards[0].title, "Editor")
        XCTAssertEqual(hub.cards[0].fileID, 5)
    }

    func testSharedFileGuideAndItem() {
        let guide = """
        <div class="guideTop"><div class="guidePreviewImage"><img src="https://i/p.jpg"></div><div class="workshopItemTitle">Guide</div>
        <div class="guideAuthors">由 A 合作完成</div><div class="guideTopDescription">intro</div></div>
        <div class="guide subSections"><div class="subSection detailBox" id="12"><div class="subSectionTitle">Part 1</div>
        <div class="subSectionDesc">body <img src="https://i/s.png"></div></div></div>
        """
        let g = try! XCTUnwrap(CommunityParsers.sharedFile(html: guide))
        XCTAssertEqual(g.kind, .guide)
        XCTAssertEqual(g.sections.map(\.title), ["Part 1"])
        XCTAssertEqual(g.sections[0].blocks.last, .image(URL(string: "https://i/s.png")!))

        let item = """
        <div class="workshopItemTitle">Forgotten</div><img id="previewImage" src="https://i/a?imw=637&imh=358&ima=fit">
        <div class="workshopItemDescription">text</div><div class="fileRatingDetails"><img src="https://c/5-star_large.png"></div>
        <div class="numRatings">518 个评价</div><div class="workshopTags"><a>Faith</a>, <a>Laser</a></div>
        <div class="rightDetailsBlock"><div class="detailsStatsContainerLeft"><div class="detailsStatLeft">文件大小</div></div>
        <div class="detailsStatsContainerRight"><div class="detailsStatRight">102 MB</div></div></div>
        """
        let i = try! XCTUnwrap(CommunityParsers.sharedFile(html: item))
        XCTAssertEqual(i.kind, .item)
        XCTAssertEqual(i.stars, 5)
        XCTAssertEqual(i.tags, ["Faith", "Laser"])
        XCTAssertEqual(i.stats, [.init(label: "文件大小", value: "102 MB")])
        XCTAssertTrue(i.images[0].absoluteString.contains("imw=1280"))
    }

    func testWorkshopSSR() throws {
        let queries: [String: Any] = ["queries": [
            ["queryKey": ["workshop_browse", [:], 1], "state": ["data": ["current_page": 1, "total_count": 61, "total_pages": 3, "results": [
                ["publishedfileid": "7", "creator": "9", "title": "Map", "preview_url": "https://i/p/", "star_rating": 4, "subscriptions": 12, "file_size": "2048",
                 "short_description": "d", "tags": [["tag": "a", "display_name": "A"]]]]]]],
            ["queryKey": ["PlayerLinkDetails", "9"], "state": ["data": ["public_data": ["persona_name": "Zed"]]]],
        ]]
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: queries), as: UTF8.self)
        let outer = String(decoding: try JSONSerialization.data(withJSONObject: ["renderContext": ["queryData": inner]]), as: UTF8.self)
        let l = try XCTUnwrap(WorkshopParser.listing(html: "<script type=\"application/json\" id=\"valve-ssr-data\">\(outer)</script>"))
        XCTAssertEqual(l.items.first?.title, "Map")
        XCTAssertEqual(l.items.first?.author, "Zed")
        XCTAssertEqual(l.items.first?.size, 2048)
        XCTAssertEqual(l.items.first?.tags, ["A"])
        XCTAssertEqual([l.total, l.pageCount], [61, 3])
    }

    func testInventoryAndRewards() throws {
        let page = """
        var g_rgAppContextData = {"753":{"appid":753,"name":"Steam","icon":"https:\\/\\/i\\/a.jpg","asset_count":55,"rgContexts":{"6":{"asset_count":54,"id":"6","name":"社区"},"1":{"asset_count":1,"id":"1","name":"礼物"}}},"9":{"appid":9,"name":"Empty","asset_count":0,"rgContexts":{}}};
        """
        let apps = InventoryParser.apps(html: page)
        XCTAssertEqual(apps.map(\.name), ["Steam"])
        XCTAssertEqual(apps[0].contexts.map(\.id), ["1", "6"])

        let json = """
        {"assets":[{"assetid":"1","classid":"5","instanceid":"0","amount":"1"},{"assetid":"2","classid":"5","instanceid":"0","amount":"1"}],
         "descriptions":[{"classid":"5","instanceid":"0","name":"Hat","name_color":"B0B0B0","icon_url":"abc","tradable":1,"marketable":0,
         "descriptions":[{"value":"Credits: <a href=\\"x\\">Ann</a>"}],"tags":[{"localized_tag_name":"Common"}]}],"more_items":1,"last_assetid":"2","total_inventory_count":2,"success":1}
        """
        let inv = try XCTUnwrap(InventoryParser.items(json: Data(json.utf8)))
        XCTAssertEqual(inv.items.count, 1)
        XCTAssertEqual(inv.items[0].count, 2)
        XCTAssertEqual(inv.items[0].lines, ["Credits: Ann"])
        XCTAssertTrue(inv.items[0].tradable)
        XCTAssertFalse(inv.items[0].marketable)
        XCTAssertEqual(inv.next, "2")

        let rewards = """
        {"response":{"definitions":[{"appid":620,"defid":1,"point_cost":"0","active":true,"community_item_data":{"item_name":"Bundle"}},
        {"appid":620,"defid":2,"point_cost":"3000","active":true,"community_item_data":{"item_name":"Wheatley","item_image_small":"s.gif","item_image_large":"l.jpg","animated":true}}],
        "total_count":17,"next_cursor":"abc"}}
        """
        let r = try XCTUnwrap(RewardsParser.page(json: Data(rewards.utf8), appid: 620))
        XCTAssertEqual(r.items.map(\.name), ["Wheatley"])
        XCTAssertTrue(r.items[0].image?.absoluteString.hasSuffix("/620/l.jpg") == true)
        XCTAssertEqual([r.total], [17])
        XCTAssertEqual(r.cursor, "abc")
    }
}

final class CommunityLeftoverTests: XCTestCase {
    func testVanityAndMyPages() {
        func page(_ s: String) -> CommunityPage? { CommunityPage.page(for: URL(string: s)!) }
        XCTAssertEqual(page("https://steamcommunity.com/id/gaben"), .user(.vanity("gaben"), .profile))
        XCTAssertEqual(page("https://steamcommunity.com/id/gaben/inventory/#730_2"), .user(.vanity("gaben"), .inventory(appid: 730)))
        XCTAssertEqual(page("https://steamcommunity.com/my/"), .user(.me, .profile))
        XCTAssertEqual(page("https://steamcommunity.com/my/tradeoffers/sent"), .user(.me, .tradeOffers(sent: true)))
        XCTAssertEqual(page("https://steamcommunity.com/my/commentnotifications/"), .user(.me, .profile))
        XCTAssertEqual(page("https://steamcommunity.com/profiles/76561198735163279/edit/info"), .user(.id("76561198735163279"), .editProfile))
        XCTAssertEqual(page("https://steamcommunity.com/profiles/76561198735163279/tradeoffers/"), .user(.id("76561198735163279"), .tradeOffers(sent: false)))
        XCTAssertNil(page("https://steamcommunity.com/id/gaben/friends"))
        XCTAssertNil(page("https://steamcommunity.com/my/friends/pending"))
    }

    func testVanityXML() {
        XCTAssertEqual(VanityResolver.steamID(xml: "<profile><steamID64>76561197960287930</steamID64><steamID><![CDATA[x]]></steamID></profile>"), "76561197960287930")
        XCTAssertNil(VanityResolver.steamID(xml: "<response><error><![CDATA[The specified profile could not be found.]]></error></response>"))
        XCTAssertEqual(VanityResolver.url("a b")?.absoluteString, "https://steamcommunity.com/id/a%20b/?xml=1")
    }

    func testCommentThreadAndPage() {
        let html = #"""
        <script>InitializeCommentThread( "PublishedFile_Public", "PublishedFile_Public_76561199085568010_3005262277", {"feature":"3005262277","feature2":-1,"owner":"76561199085568010","commentthreadid":"514147734","total_count":2,"start":0,"pagesize":10,"extended_data":"{\"appid\":620}"}, 'https://steamcommunity.com/comment/PublishedFile_Public/', 40 );</script>
        """#
        let thread = CommentParsers.thread(html: html)
        XCTAssertEqual(thread, CommentThread(type: "PublishedFile_Public", owner: "76561199085568010", feature: "3005262277", feature2: "-1", total: 2, extendedData: #"{"appid":620}"#))
        XCTAssertEqual(thread?.renderURL.absoluteString, "https://steamcommunity.com/comment/PublishedFile_Public/render/76561199085568010/3005262277/")
        XCTAssertEqual(thread?.postURL.absoluteString, "https://steamcommunity.com/comment/PublishedFile_Public/post/76561199085568010/3005262277/")
        XCTAssertEqual(CommentThread.profile("7656").renderURL.absoluteString, "https://steamcommunity.com/comment/Profile/render/7656/-1/")

        let comments = #"""
        <div class="commentthread_comment responsive_body_text" id="comment_690868475627982909"><div class="commentthread_comment_content">
          <div class="commentthread_comment_author"><div class="commentthread_comment_avatar playerAvatar offline">
            <a href="https://steamcommunity.com/id/cat" data-miniprofile="1142787040"><picture><img srcset="https://shared.akamai.steamstatic.com/a.gif"></picture></a></div>
            <div class="author_name_group"><a class="hoverunderline commentthread_author_link" href="https://steamcommunity.com/id/cat" data-miniprofile="1142787040"><bdi>Robert the cat</bdi></a>
            <div class="commentthread_comment_timestamp" title="x" data-timestamp="1764537875">2025 年 11 月 30 日</div></div></div>
          <div class="commentthread_comment_text" id="comment_content_690868475627982909">Nice <img src="https://community.akamai.steamstatic.com/economy/emoticon/steamthumbsup" alt=":steamthumbsup:" class="emoticon"></div></div></div>
        """#
        let json = try! JSONSerialization.data(withJSONObject: ["success": true, "start": 0, "pagesize": "10", "total_count": 23, "comments_html": comments] as [String: Any])
        let page = CommentParsers.page(json: json)
        XCTAssertEqual(page?.total, 23)
        XCTAssertEqual(page?.pageCount, 3)
        XCTAssertEqual(page?.comments.count, 1)
        let c = page?.comments.first
        XCTAssertEqual(c?.id, "690868475627982909")
        XCTAssertEqual(c?.author, "Robert the cat")
        XCTAssertEqual(c?.authorURL, URL(string: "https://steamcommunity.com/id/cat"))
        XCTAssertEqual(c?.avatar, URL(string: "https://shared.akamai.steamstatic.com/a.gif"))
        XCTAssertEqual(c?.date, Date(timeIntervalSince1970: 1764537875))
        XCTAssertEqual(c?.blocks.first?.plain, "Nice :steamthumbsup:")
        XCTAssertNil(CommentParsers.postError(json: Data(#"{"success":true}"#.utf8)))
        XCTAssertEqual(CommentParsers.postError(json: Data(#"{"success":false,"error":"too fast"}"#.utf8)), "too fast")
    }

    func testTradeOffers() {
        let html = """
        <div class="tradeoffer" id="tradeofferid_42"><div class="tradeoffer_items_ctn active">
          <div class="tradeoffer_header">Bob 向您发送了一个交易请求</div>
          <div class="tradeoffer_partner"><div class="playerAvatar online" data-miniprofile="1000"><img src="https://avatars.akamai.steamstatic.com/x.jpg"></div></div>
          <div class="tradeoffer_items primary"><div class="tradeoffer_items_header">对方将提供：</div><div class="tradeoffer_item_list">
            <div class="trade_item"><img src="https://community.akamai.steamstatic.com/economy/image/a/96fx96f" alt="Key"></div></div></div>
          <div class="tradeoffer_items secondary"><div class="tradeoffer_items_header">您将提供：</div><div class="tradeoffer_item_list"></div></div>
          <div class="tradeoffer_message"><div class="quote">hi</div></div></div></div>
        """
        let list = TradeOfferParser.list(html: html)
        XCTAssertEqual(list.offers.count, 1)
        XCTAssertEqual(list.offers[0].id, "42")
        XCTAssertEqual(list.offers[0].partnerID, "76561197960266728")
        XCTAssertEqual(list.offers[0].sides.map(\.items.count), [1, 0])
        XCTAssertEqual(list.offers[0].sides[0].items[0].title, "Key")
        XCTAssertEqual(list.offers[0].message, "hi")
        let empty = TradeOfferParser.list(html: #"<div class="tradeoffer_welcome_ctn"><h2>您目前没有收到任何交易请求。</h2></div>"#)
        XCTAssertTrue(empty.offers.isEmpty)
        XCTAssertEqual(empty.emptyNote, "您目前没有收到任何交易请求。")
    }

    func testProfileEditData() {
        let json = #"{"strPersonaName":"Me","strCustomURL":"","strRealName":"R","strSummary":"hi","LocationData":{"locCountry":"China","locCountryCode":"CN","locState":"Beijing","locStateCode":"22","locCity":"","locCityCode":""},"ProfilePreferences":{"hide_profile_awards":0}}"#
        let escaped = json.replacingOccurrences(of: "\"", with: "&quot;")
        let data = ProfileEditData.parse(html: "<div id=\"profile_edit_config\" data-profile-edit=\"\(escaped)\"></div>")
        XCTAssertEqual(data?.personaName, "Me")
        XCTAssertEqual(data?.countryCode, "CN")
        XCTAssertEqual(data?.stateCode, "22")
        XCTAssertEqual(data?.hideProfileAwards, false)
        let rows = ProfileEditParsers.locations(json: Data(#"[{"countrycode":"CN","hasstates":1,"countryname":"China"},{"countrycode":"CN","statecode":"01","statename":"Anhui"},{"cityid":5,"cityname":"X"}]"#.utf8))
        XCTAssertEqual(rows.map(\.code), ["CN", "01", "5"])
        XCTAssertNil(ProfileEditParsers.saveError(json: Data(#"{"success":1}"#.utf8)))
        XCTAssertEqual(ProfileEditParsers.saveError(json: Data(#"{"success":0,"errmsg":"<b>Too long</b>"}"#.utf8)), "Too long")
    }

    func testPointsAndSubscriptionParsing() {
        let summary = SteamUI.parsePoints(Data(#"{"summary":{"points":"1200","points_earned":"2000","points_spent":"800"}}"#.utf8))
        XCTAssertEqual(summary, SteamUI.PointsSummary(points: 1200, earned: 2000, spent: 800))
        let set = SteamUI.parseInList(Data(#"{"files":[{"publishedfileid":"5","inlist":true},{"publishedfileid":"6","inlist":false}]}"#.utf8))
        XCTAssertEqual(set, [5])
    }
}
