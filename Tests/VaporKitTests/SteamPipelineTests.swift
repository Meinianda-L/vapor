import XCTest
@testable import VaporKit

final class SteamPipelineTests: XCTestCase {
    // MARK: install scripts

    func testGameScriptRegistryExpandsInstallDir() throws {
        let kv = try TextVDF.parse("""
        "installscript"
        {
            "utf8_registry_strings"  "1"
            "registry"
            {
                "hkey_local_machine\\\\software\\\\valve\\\\cs2"
                {
                    "string" { "installpath" "%INSTALLDIR%" }
                    "dword" { "Installed" "1" }
                }
            }
        }
        """)
        let s = InstallScript(kv, installDir: "C:\\Games\\CS2")
        XCTAssertEqual(s.registry, [
            .init(key: "hkey_local_machine\\software\\valve\\cs2", name: "installpath", value: .string("C:\\Games\\CS2")),
            .init(key: "hkey_local_machine\\software\\valve\\cs2", name: "Installed", value: .dword(1)),
        ])
        XCTAssertTrue(s.runs.isEmpty)
    }

    func testRunProcessEntries() throws {
        let kv = try TextVDF.parse("""
        "InstallScript"
        {
            "Run Process"
            {
                "x64 14.28.29334.0"
                {
                    "HasRunKey"  "HKEY_LOCAL_MACHINE\\\\Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\vcredist\\\\2019"
                    "process 1"  "%INSTALLDIR%\\\\_CommonRedist\\\\vcredist\\\\2019\\\\Microsoft Visual C++ 2019 x64.cmd"
                    "NoCleanUp"  "1"
                    "Requirement_OS" { "Is64BitWindows" "1" }
                }
                "dxsetup"
                {
                    "process 1"  "%installdir%\\\\DXSETUP.exe"
                    "command 1"  "/silent"
                }
            }
        }
        """)
        let s = InstallScript(kv, installDir: "C:\\Steamworks Shared")
        XCTAssertEqual(s.runs.count, 2)
        XCTAssertEqual(s.runs[0].steps, [.init(program: "C:\\Steamworks Shared\\_CommonRedist\\vcredist\\2019\\Microsoft Visual C++ 2019 x64.cmd", arguments: "")])
        XCTAssertTrue(s.runs[0].requires64Bit)
        XCTAssertEqual(s.runs[0].doneMarker?.name, "x64 14.28.29334.0")
        XCTAssertEqual(s.runs[1].steps, [.init(program: "C:\\Steamworks Shared\\DXSETUP.exe", arguments: "/silent")])
        XCTAssertFalse(s.runs[1].requires64Bit)
        XCTAssertNil(s.runs[1].doneMarker)

        // Steam records the vcredist run in the 32-bit view; the entry without a HasRunKey always runs.
        var reg = RegistrySnapshot()
        reg.add("""
        [Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\vcredist\\\\2019] 1791247786
        #time=1dd552c95717b2c
        "x64 14.28.29334.0"=dword:00000001
        """, hive: "HKEY_LOCAL_MACHINE")
        XCTAssertEqual(s.pendingRuns(in: reg).map(\.name), ["dxsetup"])
        XCTAssertEqual(s.pendingRuns(in: RegistrySnapshot()).count, 2)
    }

    func testRegistrySnapshotValues() {
        var reg = RegistrySnapshot()
        reg.add("""
        [Software\\\\Wine\\\\AppDefaults\\\\MK11.exe\\\\DllOverrides] 1792803975
        "atiadlxx"=""
        "d3d11"="native"
        [Software\\\\Valve\\\\Off] 1
        "flag"=dword:00000000
        """, hive: "HKEY_CURRENT_USER")
        XCTAssertTrue(reg.isSet("HKCU\\Software\\Wine\\AppDefaults\\mk11.exe\\DllOverrides", "D3D11"))
        XCTAssertFalse(reg.isSet("HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\MK11.exe\\DllOverrides", "atiadlxx"))
        XCTAssertFalse(reg.isSet("HKEY_CURRENT_USER\\Software\\Valve\\Off", "flag"))
        XCTAssertFalse(reg.isSet("HKEY_LOCAL_MACHINE\\Software\\Wine\\AppDefaults\\MK11.exe\\DllOverrides", "d3d11"))
    }

    func testRegFileText() {
        let text = RegFile.text([
            .value(.init(key: "hkey_local_machine\\software\\valve\\cs2", name: "installpath", value: .string("C:\\Games\\\"CS2\""))),
            .value(.init(key: "HKEY_LOCAL_MACHINE\\Software\\Valve\\cs2", name: "n", value: .dword(0x1a))),
            .value(.init(key: "HKCU\\Software\\Wine\\AppDefaults\\game.exe\\DllOverrides", name: "d3d11", value: .string("native"))),
            .deleteValue(key: "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\game.exe\\DllOverrides", name: "dxgi"),
        ])
        XCTAssertEqual(text, "Windows Registry Editor Version 5.00\r\n"
            + "\r\n[HKEY_LOCAL_MACHINE\\software\\Wow6432Node\\valve\\cs2]\r\n"
            + "\"installpath\"=\"C:\\\\Games\\\\\\\"CS2\\\"\"\r\n"
            + "\r\n[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Valve\\cs2]\r\n"
            + "\"n\"=dword:0000001a\r\n"
            + "\r\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\game.exe\\DllOverrides]\r\n"
            + "\"d3d11\"=\"native\"\r\n"
            + "\"dxgi\"=-\r\n")
        XCTAssertEqual(Array(RegFile.data([]).prefix(2)), [0xFF, 0xFE])
        XCTAssertEqual(RegFile.target("HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\X"), "HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\X")
        XCTAssertEqual(RegFile.target("HKEY_LOCAL_MACHINE\\System\\X"), "HKEY_LOCAL_MACHINE\\System\\X")
    }

    func testInstallerExitCodes() {
        XCTAssertTrue([0, 1638, 3010].allSatisfy(WindowsSteam.installerSucceeded))
        XCTAssertFalse(WindowsSteam.installerSucceeded(1603))
    }

    func testWindowsPath() {
        let steam = WindowsSteam(prefix: URL(fileURLWithPath: "/Users/me/Prefix"), engine: URL(fileURLWithPath: "/Engine"))
        XCTAssertEqual(steam.windowsPath(for: URL(fileURLWithPath: "/Users/me/Prefix/drive_c/Program Files (x86)/Steam")),
                       "C:\\Program Files (x86)\\Steam")
        XCTAssertEqual(steam.windowsPath(for: URL(fileURLWithPath: "/tmp/a b.reg")), "Z:\\tmp\\a b.reg")
    }

    // MARK: Steam launch renderer

    func testSteamLaunchRenderers() {
        XCTAssertNil(SteamLaunchRenderer.modules(for: .dxmt))
        XCTAssertNil(SteamLaunchRenderer.modules(for: .d3dMetal))
        XCTAssertEqual(SteamLaunchRenderer.modules(for: .wined3d), [])
        XCTAssertEqual(SteamLaunchRenderer.modules(for: .dxvkMoltenVK)?.contains("d3d11"), true)
        let key = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Game.exe\\DllOverrides"
        XCTAssertEqual(SteamLaunchRenderer.overrides(executables: ["Game.exe"], modules: ["d3d11", "dxgi"]), [
            .value(.init(key: key, name: "d3d11", value: .string("native"))),
            .value(.init(key: key, name: "dxgi", value: .string("native"))),
        ])
        XCTAssertEqual(SteamLaunchRenderer.removal(executables: ["Game.exe"], modules: ["d3d11"]), [.deleteValue(key: key, name: "d3d11")])
    }

    // MARK: cloud sync

    private func state(_ s: SteamUI.CloudStatus, enabled: Bool = true) -> SteamUI.CloudState { .init(status: s, enabled: enabled) }

    func testCloudBeforeLaunchUpToDateGoesStraightOn() {
        var plan = CloudSyncPlan(phase: .beforeLaunch)
        XCTAssertEqual(plan.next(state(.synchronized)), .done(.synchronized))
        var off = CloudSyncPlan(phase: .beforeLaunch)
        XCTAssertEqual(off.next(state(.synchronized, enabled: false)), .done(.notUsed))
        XCTAssertEqual(off.next(nil), .done(.notUsed))
    }

    func testCloudBeforeLaunchDownloadsChanges() {
        var plan = CloudSyncPlan(phase: .beforeLaunch)
        XCTAssertEqual(plan.next(state(.outOfSync)), .sync)
        XCTAssertEqual(plan.next(state(.downloading)), .wait)
        XCTAssertEqual(plan.next(state(.synchronized)), .done(.synchronized))
    }

    func testCloudConflictAndPending() {
        var plan = CloudSyncPlan(phase: .beforeLaunch)
        XCTAssertEqual(plan.next(state(.conflict)), .done(.conflict))
        var pending = CloudSyncPlan(phase: .beforeLaunch)
        XCTAssertEqual(pending.next(state(.pendingElsewhere)), .done(.pendingElsewhere))
    }

    func testCloudAfterExitAlwaysSyncsAndSettles() {
        var plan = CloudSyncPlan(phase: .afterExit)
        XCTAssertEqual(plan.next(state(.synchronized)), .sync)
        // Steam has not moved yet: a few polls before the unchanged status is believed.
        for _ in 0..<CloudSyncPlan.settlePolls { XCTAssertEqual(plan.next(state(.synchronized)), .wait) }
        XCTAssertEqual(plan.next(state(.synchronized)), .done(.synchronized))

        var uploading = CloudSyncPlan(phase: .afterExit)
        XCTAssertEqual(uploading.next(state(.synchronized)), .sync)
        XCTAssertEqual(uploading.next(state(.uploading)), .wait)
        XCTAssertEqual(uploading.next(state(.synchronized)), .done(.synchronized))
    }

    func testCloudFailureAfterRetry() {
        var plan = CloudSyncPlan(phase: .beforeLaunch)
        XCTAssertEqual(plan.next(state(.syncFailed)), .sync)
        XCTAssertEqual(plan.next(state(.checking)), .wait)
        XCTAssertEqual(plan.next(state(.syncFailed)), .done(.failed))
    }

    func testCloudStatusKeys() {
        XCTAssertEqual(SteamUI.CloudStatus(rawValue: 3)?.stringKey, "Synchronized")
        XCTAssertEqual(SteamUI.CloudStatus(rawValue: 10)?.stringKey, "PendingElsewhere")
        XCTAssertTrue(SteamUI.CloudStatus.downloading.isTransferring)
        XCTAssertFalse(SteamUI.CloudState(status: .disabled).inUse)
    }
}
