import XCTest
@testable import VaporKit

final class SteamDialogTests: XCTestCase {
    private func snapshot(_ json: String) throws -> SteamUI.Snapshot {
        try JSONDecoder().decode(SteamUI.Snapshot.self, from: Data(json.utf8))
    }

    func testCloudConflictDialogAndLaunch() throws {
        let s = try snapshot("""
        {"loggedIn": true, "dialogs": [{"id": "m1-1", "kind": "cloudConflict", "appid": 730,
          "title": {"text": "Cloud Conflict", "key": "CloudConflict_AppLaunch_Header", "args": []},
          "message": [{"text": "Your local Counter-Strike 2 save…", "key": "CloudConflict_AppLaunch_Description", "args": ["Counter-Strike 2"]}],
          "note": {"text": "Note", "key": "CloudConflict_AppLaunch_Footer_Note", "args": []},
          "buttons": [{"id": "KeepLocal", "label": {"text": "Local Save", "key": "CloudConflict_KeepLocal", "args": []}, "role": null},
                      {"id": "KeepRemote", "label": {"text": "Cloud Save", "key": "CloudConflict_KeepRemote", "args": []}, "role": null},
                      {"id": "cancel", "label": {"text": "Cancel", "key": "Button_Cancel", "args": []}, "role": "cancel"}],
          "eulas": null, "keys": null, "code": 0, "details": null, "localTime": 1794000000, "remoteTime": 1794100000}],
         "launches": [{"gameActionID": 41, "appid": 730, "task": "DownloadingDepots", "details": "", "request": null,
                       "done": 25, "total": 100, "secondsRemaining": 12}],
         "shutdown": null, "windows": [{"title": {"text": "Steam Settings", "key": "Settings_Title", "args": []}, "time": 1794000000}]}
        """)
        let d = try XCTUnwrap(s.dialogs?.first)
        XCTAssertEqual(d.kind, "cloudConflict")
        XCTAssertEqual(d.appid, 730)
        XCTAssertEqual(d.message.first?.args, ["Counter-Strike 2"])
        XCTAssertEqual(d.buttons.map(\.id), ["KeepLocal", "KeepRemote", "cancel"])
        XCTAssertEqual(d.cancelChoice?.id, "cancel")
        XCTAssertEqual(d.remoteTime, 1_794_100_000)
        XCTAssertEqual(s.launches?.first?.fraction, 0.25)
        XCTAssertEqual(s.windows?.first?.title?.key, "Settings_Title")
        XCTAssertNil(s.shutdown)
    }

    func testOddFieldsAreLenient() throws {
        // A button without a label, a message that is not text and a non-numeric code must not lose the dialog.
        let s = try snapshot("""
        {"dialogs": [{"id": "x-2", "title": null, "message": [null, {"text": "Probe"}, 7],
                      "buttons": [{"id": "button:0"}, "junk"], "code": "?"}, 12],
         "shutdown": {"state": 3, "reason": 1, "appid": 0, "allowForceQuit": true}}
        """)
        let d = try XCTUnwrap(s.dialogs?.first)
        XCTAssertEqual(s.dialogs?.count, 1)
        XCTAssertEqual(d.kind, "generic")
        XCTAssertEqual(d.message.map(\.text), ["Probe"])
        XCTAssertNil(d.message.first?.key)
        XCTAssertEqual(d.buttons.first?.label.text, "button:0")
        XCTAssertNil(d.cancelChoice)
        XCTAssertEqual(d.code, 0)
        XCTAssertEqual(s.shutdown?.state, 3)
        XCTAssertEqual(s.shutdown?.allowForceQuit, true)
        XCTAssertEqual(s.shutdown?.failed, false)
    }

    func testOlderAgentSendsNoDialogs() throws {
        let s = try snapshot(#"{"loggedIn": true, "downloads": []}"#)
        XCTAssertNil(s.dialogs)
        XCTAssertNil(s.launches)
        XCTAssertNil(s.windows)
    }

    func testLaunchWithoutTotalHasNoFraction() throws {
        let l = try JSONDecoder().decode(SteamUI.Launch.self, from: Data(#"{"gameActionID": 3, "appid": 10, "task": "Starting"}"#.utf8))
        XCTAssertNil(l.fraction)
        XCTAssertNil(l.request)
        XCTAssertEqual(l.id, 3)
    }

    func testPrefixUpdateFollowsWineTimestamp() {
        let inf = Date(timeIntervalSince1970: 1_791_201_434.6)
        XCTAssertFalse(WindowsSteam.prefixNeedsUpdate(stamp: "1791201434\n", wineInf: inf))
        XCTAssertTrue(WindowsSteam.prefixNeedsUpdate(stamp: "1780000000", wineInf: inf))
        XCTAssertTrue(WindowsSteam.prefixNeedsUpdate(stamp: nil, wineInf: inf))
        XCTAssertFalse(WindowsSteam.prefixNeedsUpdate(stamp: "disable", wineInf: inf))
    }

    func testStringsTakeArgumentArrays() {
        let strings = SteamStrings(table: ["AppLaunchError_Text_Long": "启动此游戏时发生错误：%1$s - %2$s"])
        XCTAssertEqual(strings.text("AppLaunchError_Text_Long", ["更新已暂停", "x"]), "启动此游戏时发生错误：更新已暂停 - x")
        XCTAssertNil(strings.text("Missing", []))
    }

    // MARK: templates

    private let english = [
        "Settings_Title": "Steam Settings",
        "Generic_Close": "Close",
        "Button_Close": "Close",
        "Cloud_SyncFailed": "Cloud sync for %1$s failed (error %2$s)",
        "Notification_FriendInGame_Body": "is now playing %1$s",
        "Wide": "%1$s",
        "Pair": "%2$s of %1$s",
        "Download_Of": "Download of %1$s failed.",
        "Download_Of_Long": "Download of %1$s failed. Check your connection and %2$s.",
    ]
    private let chinese = [
        "Generic_Close": "关闭",
        "Button_Close": "关闭按钮",
        "Cloud_SyncFailed": "%1$s 的云同步失败（错误 %2$s）",
        "Notification_FriendInGame_Body": "正在玩 %1$s",
        "Pair": "%1$s 中的 %2$s",
        "Download_Of": "%1$s 下载失败。",
        "Download_Of_Long": "%1$s 下载失败，请检查网络并%2$s。",
    ]

    func testRenderedTextMapsBackToItsTemplate() {
        let s = SteamStrings(table: chinese, english: english)
        XCTAssertEqual(s.localize("Cloud sync for Counter-Strike 2 failed (error 17)"), "Counter-Strike 2 的云同步失败（错误 17）")
        XCTAssertEqual(s.match("is now playing Hades")?.args, ["Hades"])
        XCTAssertEqual(s.localize("is now playing Hades"), "正在玩 Hades")
        // The argument order follows the placeholder numbers, not their position.
        XCTAssertEqual(s.match("3 of 9")?.args, ["9", "3"])
        XCTAssertEqual(s.localize("3 of 9"), "9 中的 3")
    }

    func testPlainTextAndSpecificity() {
        let s = SteamStrings(table: chinese, english: english)
        XCTAssertEqual(s.localize("Close"), "关闭按钮")                    // among shared texts a plain Button_ token, deterministically
        // The longer template wins over the shorter one that also fits.
        XCTAssertEqual(s.match("Download of Portal failed. Check your connection and try again.")?.key, "Download_Of_Long")
        XCTAssertEqual(s.match("Download of Portal failed.")?.key, "Download_Of")
        XCTAssertNil(s.match("Something Steam never says"))
        XCTAssertNil(s.match("   "))
        // A bare "%1$s" token must not claim every text.
        XCTAssertNil(s.match("Hello"))
        // No translation: nothing to substitute.
        XCTAssertNil(SteamStrings(table: [:], english: english).localize("is now playing Hades"))
    }

    func testBundlesInBothQuotingStylesParse() {
        let single = "x.push([[1],{2:(e=>{e.exports=JSON.parse('{\\\"A\\\":1}')})}]);JSON.parse('{\"B\":\"\\u5173\\u95ED\"}')"
        XCTAssertEqual(SteamStrings.parse(bundle: single)["B"], "关闭")
        let template = "x.exports=JSON.parse(`{\"Cloud\":\"say \\\\\"hi\\\\\" %1$s\",\"Nl\":\"a\\\\nb\"}`)"
        let parsed = SteamStrings.parse(bundle: template)
        XCTAssertEqual(parsed["Cloud"], "say \"hi\" %1$s")
        XCTAssertEqual(parsed["Nl"], "a\nb")
    }

    func testSteamsOwnEnglishBundleLoadsWhenInstalled() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/Heroic/Prefixes/Steam/drive_c/Program Files (x86)/Steam")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.appendingPathComponent("steamui/localization/steamui_english-json.js").path))
        let s = SteamStrings(steamRoot: root)
        XCTAssertEqual(s.localize("Cloud Conflict"), s("CloudConflict_AppLaunch_Header"))
        XCTAssertEqual(s.match("Friend is now online")?.key, "Notification_FriendOnline_Body_Short")
        let local = s.localize("is now playing Hades")
        XCTAssertTrue(local?.contains("Hades") == true, local ?? "nil")
        XCTAssertFalse(local?.contains("%1$s") == true)
    }

    // MARK: windows, toasts, remembered launch option

    func testHiddenWindowKinds() throws {
        let s = try snapshot("""
        {"windows": [
          {"title": {"text": "Steam Settings"}, "time": 5, "at": 1000, "kind": "settings"},
          {"title": {"text": "Friends List"}, "time": 6, "at": 1001, "kind": "friends"},
          {"title": {"text": "Ann"}, "time": 7, "at": 1002, "kind": "chat", "steamID": "76561198000000001"},
          {"title": {"text": "Ann"}, "time": 7, "at": 1003, "kind": "chat", "steamID": null},
          {"title": null, "time": 8, "at": 1004, "kind": "downloads"},
          {"title": null, "time": 9, "at": 1005, "kind": "library", "appid": 730},
          {"title": null, "time": 9, "at": 1006, "kind": "store", "appid": 620, "url": "https://store.steampowered.com/app/620"},
          {"title": null, "time": 9, "at": 1007, "kind": "store"},
          {"title": {"text": "Whatever"}, "time": 10, "at": 1008, "kind": "wizard-of-oz"},
          {"title": {"text": "Old agent"}, "time": 11}]}
        """)
        let kinds = try XCTUnwrap(s.windows).map(\.kind)
        XCTAssertEqual(kinds, [.settings, .friends, .chat(steamID: "76561198000000001"), .chat(steamID: nil), .downloads,
                               .library(appid: 730), .store(appid: 620), .store(appid: nil), .other, .other])
        XCTAssertEqual(s.windows?[6].url, "https://store.steampowered.com/app/620")
        XCTAssertEqual(s.windows?.last?.at, 0)
    }

    func testToastsAndRememberCheckboxDecode() throws {
        let s = try snapshot("""
        {"toasts": [{"id": "notificationtoasts_41_desktop", "appid": 0, "time": 3,
                     "lines": [{"text": "Ann", "key": null, "args": []}, {"text": "is now playing Hades", "key": null, "args": []}]}, 4],
         "dialogs": [{"id": "a-1", "kind": "launchOption", "appid": 10, "title": {"text": "CS"}, "message": [],
                      "remember": {"text": "Always use this selection", "key": "LaunchOptionsDialog_Remember", "args": []},
                      "buttons": [{"id": "0", "label": {"text": "Play"}, "role": "default"}]},
                     {"id": "a-2", "kind": "microtxn", "appid": 10, "title": {"text": "Microtransaction Authorization"},
                      "message": [{"text": "Gem pack"}], "details": "$4.99",
                      "buttons": [{"id": "authorize", "label": {"text": "Authorize"}}, {"id": "cancel", "label": {"text": "Cancel"}, "role": "cancel"}]}]}
        """)
        XCTAssertEqual(s.toasts?.count, 1)
        XCTAssertEqual(s.toasts?.first?.lines.map(\.text), ["Ann", "is now playing Hades"])
        XCTAssertEqual(s.dialogs?.first?.remember?.key, "LaunchOptionsDialog_Remember")
        let buy = try XCTUnwrap(s.dialogs?.last)
        XCTAssertEqual(buy.details, "$4.99")
        XCTAssertNil(buy.buttons.first { $0.id == "authorize" }?.role)   // never the default answer
        XCTAssertEqual(buy.cancelChoice?.id, "cancel")
        XCTAssertNil(s.dialogs?.last?.remember)
    }

    func testAgentIsVersion17() {
        XCTAssertEqual(SteamUI.agentVersion, 17)
        XCTAssertTrue(SteamUI.agentSource.contains("version: \(SteamUI.agentVersion)"))
    }
}
