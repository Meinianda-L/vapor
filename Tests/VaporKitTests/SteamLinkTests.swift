import XCTest
@testable import VaporKit

final class SteamLinkTests: XCTestCase {
    private func link(_ s: String) -> SteamLink { SteamLink(URL(string: s)!) }

    func testStoreButtonsMapToApps() {
        XCTAssertEqual(link("steam://launch/976310/Dialog"), .play(976310))
        XCTAssertEqual(link("steam://run/714010"), .play(714010))
        XCTAssertEqual(link("steam://install/730"), .install(730))
        XCTAssertEqual(link("steam://installaddon/2778580"), .install(2778580))
    }

    func testOpenURLStaysInsideForSteamSites() {
        XCTAssertEqual(link("steam://openurl/https://steamcommunity.com/app/976310/discussions/"),
                       .page(URL(string: "https://steamcommunity.com/app/976310/discussions/")!))
        XCTAssertEqual(link("steam://openurl/https://www.youtube.com/aimlab/"), .external(URL(string: "https://www.youtube.com/aimlab/")!))
        XCTAssertEqual(link("steam://openurl_external/https://steamcommunity.com/linkfilter/?u=https%3A%2F%2Fx.com%2Faimlab"),
                       .external(URL(string: "https://steamcommunity.com/linkfilter/?u=https%3A%2F%2Fx.com%2Faimlab")!))
    }

    func testOnlyWebURLsLeaveTheView() {
        for target in ["file:///Applications/Utilities/Terminal.app", "smb://host/share", "x-apple.systempreferences:com.apple.preference.security",
                       "javascript:alert(1)", "steam://run/730", "https://", "store.steampowered.com/app/730/"] {
            XCTAssertEqual(link("steam://openurl_external/\(target)"), .ignore, target)
            XCTAssertEqual(link("steam://openurl/\(target)"), .ignore, target)
        }
        XCTAssertEqual(link("steam://openurl_external/HTTPS://example.com/"), .external(URL(string: "HTTPS://example.com/")!))
    }

    func testSteamWebNeedsAWebScheme() {
        XCTAssertTrue(SteamLink.isSteamWeb(URL(string: "https://checkout.steampowered.com/checkout/")!))
        XCTAssertTrue(SteamLink.isSteamWeb(URL(string: "https://steamcommunity.com/")!))
        XCTAssertFalse(SteamLink.isSteamWeb(URL(string: "ftp://store.steampowered.com/")!))
        XCTAssertFalse(SteamLink.isSteamWeb(URL(string: "https://notsteampowered.com/")!))
        XCTAssertFalse(SteamLink.isSteamWeb(URL(string: "https://steampowered.com.evil.example/")!))
    }

    func testLoginCookieSteamID() {
        XCTAssertEqual(SteamLink.steamID(loginCookie: "76561198000000001%7C%7CeyJhbGciOi"), "76561198000000001")
        XCTAssertEqual(SteamLink.steamID(loginCookie: "76561198000000001||eyJhbGciOi"), "76561198000000001")
        XCTAssertNil(SteamLink.steamID(loginCookie: "deleted"))
        XCTAssertNil(SteamLink.steamID(loginCookie: "765611980000000011%7C%7Cx"))
        XCTAssertNil(SteamLink.steamID(loginCookie: "76561198000000001"))
    }

    func testUnknownAndMalformed() {
        XCTAssertEqual(link("steam://friends/status/online"), .ignore)
        XCTAssertEqual(link("steam://launch/notanid"), .ignore)
        XCTAssertEqual(link("https://store.steampowered.com/"), .ignore)
    }
}

final class SteamStringsTests: XCTestCase {
    func testParsesWebpackLocalizationChunk() {
        let bundle = #"(self.webpackChunksteamui=[]).push([[901],{1:(e=>{e.exports=JSON.parse('{"Steam_AppUpdateError_26":"地区受限","Quote":"say \\"hi\\"","Apos":"it\'s","Fmt":"已下载 %1$s / %2$s"}')})}]);"#
        let s = SteamStrings(table: SteamStrings.parse(bundle: bundle))
        XCTAssertEqual(s.appUpdateError(26), "地区受限")
        XCTAssertEqual(s("Quote"), "say \"hi\"")
        XCTAssertEqual(s("Apos"), "it's")
        XCTAssertEqual(s("Fmt", "1 GB", "2 GB"), "已下载 1 GB / 2 GB")
    }

    func testInstalledSteamHasChineseErrors() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Heroic/Prefixes/Steam/drive_c/Program Files (x86)/Steam")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.appendingPathComponent("steamui/localization").path))
        let s = SteamStrings(steamRoot: root)
        XCTAssertEqual(s.appUpdateError(26), "地区受限")
        XCTAssertEqual(s("Downloads_Section_Completed"), "已完成")
    }
}
