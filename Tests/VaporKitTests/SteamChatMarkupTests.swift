import XCTest
@testable import VaporKit

final class SteamChatMarkupTests: XCTestCase {
    private func spans(_ text: String) -> [RichSpan] {
        SteamChatMarkup.parse(text).blocks.flatMap { if case let .paragraph(s) = $0 { return s } else { return [] } }
    }

    func testEmoticonsAreInlineAndAloneTheyAreLarge() {
        let s = spans("gg [emoticon]steamhappy[/emoticon] wp")
        XCTAssertEqual(s.map(\.text), ["gg ", ":steamhappy:", " wp"])
        XCTAssertEqual(s[1].emoticon, "steamhappy")
        XCTAssertFalse(SteamChatMarkup.parse("gg [emoticon]steamhappy[/emoticon]").onlyEmoticons)
        XCTAssertTrue(SteamChatMarkup.parse("[emoticon]steamhappy[/emoticon] [emoticon]steamsad[/emoticon]").onlyEmoticons)
    }

    func testSlashCommandsKeepTheirMeaning() {
        let me = SteamChatMarkup.parse("/me waves")
        XCTAssertTrue(me.isAction)
        XCTAssertEqual(me.blocks.first?.plain, "waves")
        XCTAssertEqual(SteamChatMarkup.parse("/code let x = 1").blocks, [.code("let x = 1")])
        XCTAssertEqual(spans("/spoiler the end").first, RichSpan("the end", spoiler: true))
        XCTAssertFalse(SteamChatMarkup.parse("/mean thing").isAction)   // only the exact command word counts
        XCTAssertFalse(SteamChatMarkup.parse("/random 1 6").isAction)
    }

    func testBlocksAndInlineTags() {
        let m = SteamChatMarkup.parse(#"look [sticker type="Lovestruck" limit="0"][/sticker][quote author="Ana"]hi [b]there[/b][/quote]"#)
        XCTAssertEqual(m.blocks.count, 3)
        XCTAssertEqual(m.blocks[1], .sticker("Lovestruck"))
        guard case let .quote(author, inner) = m.blocks[2] else { return XCTFail("no quote") }
        XCTAssertEqual(author, "Ana")
        XCTAssertEqual(inner.first?.plain, "hi there")
        XCTAssertEqual(spans("[spoiler]x[/spoiler]").first?.spoiler, true)
        XCTAssertEqual(spans("[url=https://example.com/a]site[/url]").first?.link?.absoluteString, "https://example.com/a")
        XCTAssertEqual(spans("see https://example.com/x now")[1].link?.absoluteString, "https://example.com/x")
    }

    func testRandomFlipAndUnknownTags() {
        XCTAssertTrue(spans("[random min=1 max=6 result=4][/random]").map(\.text).joined().hasSuffix("4"))
        XCTAssertEqual(spans("[flip result=heads][/flip]").last?.bold, true)
        XCTAssertEqual(spans("[weird]kept[/weird]").map(\.text).joined(), "kept")
        XCTAssertEqual(spans(#"a \[b] [unclosed c"#).map(\.text).joined(), "a [b] [unclosed c")
    }

    func testCommunityEmoticonImagesBecomeEmoticonSpans() {
        let blocks = RichText.blocks(html: #"<div>nice <img src="https://community.akamai.steamstatic.com/economy/emoticon/steamhappy" alt=":steamhappy:" class="emoticon"></div>"#)
        guard case let .paragraph(s)? = blocks.first else { return XCTFail("no paragraph") }
        XCTAssertEqual(s.last?.emoticon, "steamhappy")
    }
}
