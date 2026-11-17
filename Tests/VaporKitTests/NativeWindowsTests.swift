import XCTest
@testable import VaporKit

final class NativeWindowsTests: XCTestCase {
    private func event(_ json: String) -> NativeWindows.Event? { NativeWindows.Event(line: Data(json.utf8)) }

    func testMessageBoxDecodes() throws {
        let line = ##"{"event":"show","hwnd":262530,"pid":1500,"process":"Steam.exe","class":"#32770","title":"Steam - 错误","texts":["Steam 需要联网才能更新。"," "],"buttons":[{"hwnd":131602,"id":4,"label":"&Retry","default":true,"enabled":true},{"hwnd":66072,"id":2,"label":"Cancel","default":false,"enabled":true},{"bad":1}]}"##
        guard case let .show(w)? = event(line) else { return XCTFail("no window") }
        XCTAssertEqual(w.hwnd, 262530)
        XCTAssertEqual(w.process, "steam.exe")
        XCTAssertEqual(w.texts, ["Steam 需要联网才能更新。"])
        XCTAssertEqual(w.buttons.map(\.label), ["Retry", "Cancel"])
        XCTAssertEqual(w.buttons.first?.command, 4)
        XCTAssertTrue(w.buttons.first?.isDefault ?? false)
        XCTAssertFalse(w.isStatus)
        XCTAssertEqual(w.cancelButton?.hwnd, 66072)
        XCTAssertNil(w.progress)
    }

    func testBootstrapperIsAStatus() throws {
        let line = #"{"event":"show","hwnd":7,"class":"BootstrapUpdateUIClass","title":"Steam","texts":["Downloading Update..."],"buttons":[{"hwnd":8,"id":2,"label":"&Cancel"}],"progress":{"pos":42,"min":0,"max":100,"marquee":false}}"#
        guard case let .show(w)? = event(line) else { return XCTFail("no window") }
        XCTAssertTrue(w.isStatus)
        XCTAssertEqual(w.progress?.fraction ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(w.statusLine, "正在更新 Steam… 42%")
        let marquee = ##"{"event":"show","hwnd":9,"process":"wineboot.exe","class":"#32770","texts":["x"],"buttons":[],"progress":{"pos":0,"min":0,"max":100,"marquee":true}}"##
        guard case let .show(m)? = event(marquee) else { return XCTFail("no window") }
        XCTAssertNil(m.progress?.fraction)
        XCTAssertEqual(m.statusLine, "正在更新 Wine 配置…")
    }

    func testEventsUpdateTheList() {
        var list: [NativeWindow] = []
        for line in [#"{"event":"show","hwnd":1,"title":"a"}"#, #"{"event":"show","hwnd":2,"title":"b"}"#,
                     #"{"event":"show","hwnd":1,"title":"c"}"#, #"{"event":"gone","hwnd":2}"#, "not json", #"{"event":"other"}"#] {
            if let e = event(line) { NativeWindows.apply(e, to: &list) }
        }
        XCTAssertEqual(list.map(\.title), ["c"])
        NativeWindows.apply(.ready, to: &list)
        XCTAssertTrue(list.isEmpty)
    }

    func testMnemonics() {
        XCTAssertEqual(NativeWindow.withoutMnemonic("&Retry"), "Retry")
        XCTAssertEqual(NativeWindow.withoutMnemonic("R&&D"), "R&D")
        XCTAssertEqual(NativeWindow.withoutMnemonic("OK"), "OK")
    }
}
