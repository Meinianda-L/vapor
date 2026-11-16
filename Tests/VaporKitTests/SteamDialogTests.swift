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
}
