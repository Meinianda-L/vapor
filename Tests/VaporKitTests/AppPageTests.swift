import XCTest
@testable import VaporKit

/// The app page kit's JSON, shaped like what the live client returned for CS2 and Portal 2.
final class AppPageTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testInfoReadsLogoPositionAndCloud() throws {
        let info = try XCTUnwrap(SteamUI.parseAppPageInfo(data("""
        {"cloudStatus":3,"cloudProgress":0,"cloudAvailable":true,"playtimeMinutes":224,"playtimeTwoWeeks":224,"lastPlayed":1794896826,
         "screenshots":0,"workshopVisible":true,"marketPresence":true,"developer":"Valve","homepage":"http://counter-strike.net/","manual":"",
         "releaseDate":1345568400,"isSoftware":false,"logo":{"position":"CenterCenter","widthPct":59,"heightPct":69}}
        """)))
        XCTAssertEqual(info.cloudStatus, 3)
        XCTAssertEqual(info.logo, SteamUI.LogoPosition(pin: .centerCenter, widthPct: 59, heightPct: 69))
        XCTAssertEqual(info.homepage?.absoluteString, "https://counter-strike.net/")
        XCTAssertNil(info.manual)
        XCTAssertEqual(info.lastPlayed, Date(timeIntervalSince1970: 1794896826))
        XCTAssertNil(SteamUI.parseAppPageInfo(data("null")))
    }

    func testUnknownLogoPinIsDropped() throws {
        let info = try XCTUnwrap(SteamUI.parseAppPageInfo(data(#"{"logo":{"position":"Sideways","widthPct":10,"heightPct":10}}"#)))
        XCTAssertNil(info.logo)
        XCTAssertEqual(info.playtimeMinutes, 0)
    }

    func testFriendsSkipRowsWithoutSteamID() {
        let f = SteamUI.parseAppFriends(data("""
        {"inGame":[],"recent":[{"steamID":"76561198741204815","name":"a","avatar":null,"state":0,"gameAppID":0,"minutesRecent":881,"minutesForever":42845}],
         "ever":[{"name":"broken"},{"steamID":"76561198769126972","name":"b","minutesForever":"350"}],"wishlist":null}
        """))
        XCTAssertEqual(f.recent.map(\.minutesRecent), [881])
        XCTAssertEqual(f.ever.map(\.steamID), ["76561198769126972"])
        XCTAssertEqual(f.ever.first?.minutesForever, 350)
        XCTAssertFalse(f.isEmpty)
        XCTAssertTrue(SteamUI.parseAppFriends(data("{}")).isEmpty)
    }

    func testActivityKinds() {
        let items = SteamUI.parseAppActivity(data("""
        [{"id":"2-1-1794710423","kind":"achievement","time":1794710423,"actor":{"steamID":"7656","name":"Me"},"isSelf":true,
          "unlocks":[{"name":"A New Beginning","description":"","icon":"https://x/a.jpg","time":1794710423}],"event":null,"text":"","count":0,"votedUp":null},
         {"id":"1002-3","kind":"event","time":1794438200,"actor":null,"event":{"gid":"687522235410284762","title":"Update","summary":"s","type":12,"image":null}},
         {"id":"x","kind":"somethingNew","time":1},
         {"id":"no-time","kind":"status"}]
        """))
        XCTAssertEqual(items.map(\.kind), [.achievement, .event, .other])
        XCTAssertEqual(items[0].unlocks.first?.icon?.absoluteString, "https://x/a.jpg")
        XCTAssertTrue(items[0].isSelf)
        XCTAssertNil(items[0].votedUp)
        XCTAssertEqual(items[1].event?.type, 12)
        XCTAssertEqual(items[1].event?.gid, "687522235410284762")
        XCTAssertNil(items[1].actor)
    }

    func testBadgeNeedsCards() throws {
        XCTAssertNil(SteamUI.parseAppBadge(data(#"{"name":"","cards":[]}"#)))
        let b = try XCTUnwrap(SteamUI.parseAppBadge(data("""
        {"name":"","icon":null,"level":0,"maxLevel":5,"xp":0,"maxed":false,"nextLevelName":"I'm A Potato!","nextLevelXP":100,
         "cards":[{"name":"Chell","title":"Chell","image":"https://c/1","owned":0},{"name":"Destruction","title":"Destruction","image":"https://c/2","owned":1}]}
        """)))
        XCTAssertEqual(b.missing, 1)
        XCTAssertEqual(b.nextLevelXP, 100)
    }

    func testReviewState() {
        XCTAssertEqual(SteamUI.parseReviewState(data(#"{"review":null}"#)), .none)
        guard case .reviewed(let r) = SteamUI.parseReviewState(data("""
        {"review":{"id":"123","votedUp":true,"text":"good","playtimeAtReview":61,"votesUp":2,"comments":0,"language":"schinese","isPublic":true}}
        """)) else { return XCTFail("expected a review") }
        XCTAssertEqual(r.id, "123")
        XCTAssertTrue(r.votedUp)
        XCTAssertEqual(r.playtimeAtReview, 61)
    }

    func testNotes() {
        let notes = SteamUI.parseNotes(data(#"[{"id":"abc","title":"","content":"[b]x[/b]","modified":1700000000},{"title":"no id"}]"#))
        XCTAssertEqual(notes.map(\.id), ["abc"])
        XCTAssertEqual(notes.first?.modified, Date(timeIntervalSince1970: 1700000000))
    }

    func testLocalScreenshotsPreferThumbnailsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vapor-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("userdata/774897551/760/remote/620/screenshots")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.jpg"), new = dir.appendingPathComponent("new.jpg")
        try Data().write(to: old)
        try Data().write(to: new)
        try Data().write(to: dir.appendingPathComponent("thumbnails/new.jpg"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: old.path)
        let shots = SteamUI.localScreenshots(steamRoot: root, steamID64: "76561198735163279", appid: 620)
        XCTAssertEqual(shots.map(\.lastPathComponent), ["new.jpg", "old.jpg"])
        XCTAssertEqual(shots.first?.deletingLastPathComponent().lastPathComponent, "thumbnails")
        XCTAssertEqual(SteamUI.localScreenshots(steamRoot: root, steamID64: "bogus", appid: 620), [])
    }
}
