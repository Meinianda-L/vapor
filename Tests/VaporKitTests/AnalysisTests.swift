import XCTest
@testable import VaporKit

/// Builds a minimal PE image with one section holding an import table, an
/// optional delay-import table and an optional CLR directory.
func makePE(is64: Bool, imports: [String], delayImports: [String] = [], dotNet: Bool = false, extraText: String = "") -> Data {
    let optSize = is64 ? 240 : 224
    var d = [UInt8](repeating: 0, count: 0x400)
    func put(_ bytes: [UInt8], at off: Int) { d.replaceSubrange(off..<off + bytes.count, with: bytes) }
    put([0x4D, 0x5A], at: 0)
    put(le32(0x40), at: 0x3C)
    put(le32(0x0000_4550), at: 0x40)
    put(le16(is64 ? 0x8664 : 0x14C) + le16(1), at: 0x44)
    put(le16(UInt16(optSize)), at: 0x54)
    let opt = 0x58
    put(le16(is64 ? 0x20B : 0x10B), at: opt)
    put(le16(2), at: opt + 68)                                   // GUI subsystem
    put(le32(16), at: opt + (is64 ? 108 : 92))
    let dirs = opt + (is64 ? 112 : 96)
    let sec = opt + optSize
    put(Array(".rdata".utf8), at: sec)
    put(le32(0x1000) + le32(0x1000) + le32(0x200) + le32(0x200), at: sec + 8)

    // Raw section at file 0x200 == RVA 0x1000.
    func rva(_ off: Int) -> UInt32 { UInt32(0x1000 + off) }
    var names = 0x100                                            // name strings start at section offset 0x100
    func addName(_ s: String) -> UInt32 {
        let r = rva(names); put(Array(s.utf8) + [0], at: 0x200 + names); names += s.utf8.count + 1; return r
    }
    var off = 0
    for i in imports {
        put(le32(rva(0xF0)) + le32(0) + le32(0) + le32(addName(i)) + le32(rva(0xF0)), at: 0x200 + off)
        off += 20
    }
    put(le32(rva(0)) + le32(UInt32(off + 20)), at: dirs + 8)                    // directory 1: imports
    if !delayImports.isEmpty {
        var doff = 0x60
        let start = doff
        for i in delayImports { put(le32(1) + le32(addName(i)), at: 0x200 + doff); doff += 32 }
        put(le32(rva(start)) + le32(UInt32(doff - start + 32)), at: dirs + 13 * 8)
    }
    if dotNet { put(le32(rva(0x1F0)) + le32(72), at: dirs + 14 * 8) }
    if !extraText.isEmpty { put(Array(extraText.utf8), at: 0x380) }
    return Data(d)
}

/// Builds a v28 appinfo (inline key strings) holding one Windows app with the given launch entries.
func makeAppInfo(appid: UInt32, launch: [[String: String]]) throws -> AppInfo {
    func cstr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
    func str(_ k: String, _ v: String) -> [UInt8] { [0x01] + cstr(k) + cstr(v) }
    func obj(_ k: String, _ body: [UInt8]) -> [UInt8] { [0x00] + cstr(k) + body + [0x08] }
    let entries = launch.enumerated().flatMap { i, e in
        obj(String(i), e.sorted { $0.key < $1.key }.flatMap { str($0.key, $0.value) } + obj("config", str("oslist", "windows")))
    }
    let kv = obj("appinfo", obj("common", str("name", "Game \(appid)") + str("oslist", "windows"))
                            + obj("config", str("installdir", "Game") + obj("launch", entries))) + [0x08]
    let header = [UInt8](repeating: 0, count: 4 + 4 + 8 + 20 + 4 + 20)
    let data = le32(0x0756_4428) + le32(1) + le32(appid) + le32(UInt32(header.count + kv.count)) + header + kv + le32(0)
    return try AppInfo(data: Data(data))
}

final class PEFileTests: XCTestCase {
    func testPE32ImportsAndMachine() throws {
        let pe = try PEFile(data: makePE(is64: false, imports: ["KERNEL32.dll", "d3d9.dll"]))
        XCTAssertEqual(pe.machine, .i386)
        XCTAssertFalse(pe.is64Bit)
        XCTAssertEqual(pe.imports, ["kernel32.dll", "d3d9.dll"])
        XCTAssertEqual(pe.subsystem, 2)
        XCTAssertFalse(pe.isDotNet)
    }

    func testPE32PlusDelayImportsAndDotNet() throws {
        let pe = try PEFile(data: makePE(is64: true, imports: ["user32.dll"], delayImports: ["D3D12.dll"], dotNet: true))
        XCTAssertEqual(pe.machine, .amd64)
        XCTAssertTrue(pe.is64Bit)
        XCTAssertEqual(pe.imports, ["user32.dll", "d3d12.dll"])
        XCTAssertTrue(pe.isDotNet)
    }

    func testRejectsNonPE() {
        XCTAssertThrowsError(try PEFile(data: Data(repeating: 0, count: 512)))
    }

    /// Garbage section headers (truncated download, packer) must not trap on overflow.
    func testOverflowingSectionHeaderDoesNotTrap() throws {
        var data = makePE(is64: false, imports: ["d3d9.dll"])
        let sec = 0x58 + 224, dirs = 0x58 + 96
        data.replaceSubrange(sec + 8..<sec + 24, with: le32(0x2000) + le32(0xFFFF_F000) + le32(0x200) + le32(0xFFFF_FFF0))
        data.replaceSubrange(dirs + 8..<dirs + 12, with: le32(0xFFFF_FF00))
        XCTAssertEqual(try PEFile(data: data).imports, [])
    }

    func testReferencedNamesFindsAsciiAndUTF16() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.exe")
        var data = makePE(is64: true, imports: [], extraText: "LoadLibraryA D3D11.DLL")
        data.append(contentsOf: Array("d3d12.dll".utf8).flatMap { [$0, 0] })
        try data.write(to: url)
        XCTAssertEqual(PEFile.referencedNames(in: url, candidates: ["d3d11.dll", "d3d12.dll", "d3d9.dll"]), ["d3d11.dll", "d3d12.dll"])
    }

    /// Real Wine PE DLLs from the Sikarugir engine Heroic installed, when present.
    func testRealWineDLLIfPresent() throws {
        let dxgi = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/heroic/tools/wine/Wine-10.0-Sikarugir/lib/wine/x86_64-windows/d3d11.dll")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dxgi.path))
        let pe = try PEFile(url: dxgi)
        XCTAssertEqual(pe.machine, .amd64)
        XCTAssertTrue(pe.imports.contains("kernel32.dll") || pe.imports.contains("ntdll.dll") || !pe.imports.isEmpty)
    }
}

final class GameAnalysisTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ data: Data = Data()) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Source-engine shape: exe imports nothing graphical, renderer DLL loads d3d9.
    func testSourceStyleGameIs32BitD3D9() throws {
        try write("game.exe", makePE(is64: false, imports: ["kernel32.dll", "launcher.dll"]))
        try write("bin/shaderapidx9.dll", makePE(is64: false, imports: ["d3d9.dll"]))
        try write("bin/engine.dll", makePE(is64: false, imports: ["steam_api.dll"]))
        try write("bin/vphysics.dll", makePE(is64: false, imports: []))
        let a = GameAnalyzer.analyze(installDir: dir, executable: "game.exe")
        XCTAssertTrue(a.is32Bit)
        XCTAssertEqual(a.likelyAPIs.first, .d3d9)
        XCTAssertEqual(a.engine, .source)
        XCTAssertTrue(a.usesSteamworks)
        let ladder = RendererLadder.build(for: a, settings: WineSettings())
        XCTAssertEqual(ladder.map(\.renderer), [.dxvkKosmicKrisp, .dxvkMoltenVK, .wined3d])
    }

    /// Unity with both D3D11 and D3D12: D3DMetal first, then DXMT forced to D3D11.
    func testUnityD3D12WithD3D11Fallback() throws {
        try write("game.exe", makePE(is64: true, imports: ["unityplayer.dll"]))
        try write("UnityPlayer.dll", makePE(is64: true, imports: ["d3d11.dll"], delayImports: ["d3d12.dll"]))
        let a = GameAnalyzer.analyze(installDir: dir, executable: "game.exe")
        XCTAssertEqual(a.engine, .unity)
        XCTAssertEqual(a.likelyAPIs.prefix(2), [.d3d12, .d3d11])
        let ladder = RendererLadder.build(for: a, settings: WineSettings())
        XCTAssertEqual(ladder.first?.renderer, .d3dMetal)
        XCTAssertTrue(ladder.contains { $0.renderer == .dxmt && $0.arguments == ["-force-d3d11"] })
    }

    /// MK11 shape: default exe is D3D11, a separate launch entry is the D3D12 build.
    func testSeparateDX12ExecutableBecomesItsOwnRung() throws {
        try write("Binaries/Retail/MK11.exe", makePE(is64: true, imports: ["d3d11.dll", "steam_api64.dll"]))
        try write("Binaries/Retail/MK11_DX12.exe", makePE(is64: true, imports: ["d3d12.dll", "steam_api64.dll"]))
        let a = GameAnalyzer.analyze(installDir: dir, executable: "Binaries/Retail/MK11.exe")
        XCTAssertEqual(a.likelyAPIs, [.d3d11], "the DX12 exe must not leak into the main exe's APIs")
        XCTAssertEqual(a.otherExecutables["binaries/retail/mk11_dx12.exe"], .init(apis: [.d3d12], is32Bit: false))
        let dx12 = AppMetadata.LaunchEntry(index: "3", executable: "Binaries/Retail/MK11_DX12.exe", arguments: "", workingDir: "",
                                           osList: ["windows"], osArch: "", type: "option3", description: "DirectX 12", betaKey: "")
        let ladder = RendererLadder.build(for: a, settings: WineSettings(), alternates: [LaunchPlan.resolving(dx12, in: dir)])
        XCTAssertEqual(ladder[0].renderer, .dxmt)
        XCTAssertNil(ladder[0].executable)
        XCTAssertEqual(ladder[1].renderer, .d3dMetal)
        XCTAssertEqual(ladder[1].executable, "Binaries/Retail/MK11_DX12.exe")
    }

    func testBetaOnlyLaunchEntriesAreIgnoredAndPathsNormalised() {
        XCTAssertEqual(AppMetadata.normalizeExecutable("\\Binaries\\Retail\\MK11.exe"), "Binaries/Retail/MK11.exe")
        let beta = AppMetadata.LaunchEntry(index: "1", executable: "a.exe", arguments: "", workingDir: "", osList: ["windows"],
                                           osArch: "", type: "option1", description: "", betaKey: "test1")
        XCTAssertFalse(beta.isPlayableWindowsEntry)
    }

    func test32BitD3D11NeverUsesD3DMetal() throws {
        try write("game.exe", makePE(is64: false, imports: ["d3d11.dll"]))
        let ladder = RendererLadder.build(for: GameAnalyzer.analyze(installDir: dir, executable: "game.exe"), settings: WineSettings())
        XCTAssertFalse(ladder.contains { $0.renderer == .d3dMetal })
        XCTAssertEqual(ladder.first?.renderer, .dxmt)
    }

    func testValveNod3d10KeepsWineD3D() throws {
        try write("game.exe", makePE(is64: true, imports: ["d3d10.dll"]))
        let (settings, _) = QuirkTranslator.translate(["nod3d10"], engine: .crossOverBased)
        let ladder = RendererLadder.build(for: GameAnalyzer.analyze(installDir: dir, executable: "game.exe"), settings: settings)
        XCTAssertEqual(ladder.map(\.renderer), [.wined3d])
    }

    func testAntiCheatVerdicts() throws {
        try write("game.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        try write("EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe")
        let db = AntiCheatDB(entries: [
            1: .init(name: "Denied", status: "Denied", antiCheats: ["Easy Anti-Cheat"], dateChanged: "2024-01-19"),
            2: .init(name: "OK", status: "Supported", antiCheats: ["Easy Anti-Cheat"], dateChanged: "2025-01-01"),
            4: .init(name: "Broken", status: "Broken", antiCheats: ["Easy Anti-Cheat"], dateChanged: "2025-01-01"),
            5: .init(name: "Kernel", status: "Broken", antiCheats: ["Denuvo Anti-Cheat"], dateChanged: "2025-01-01"),
            6: .init(name: "Bare", status: "Denied", antiCheats: [], dateChanged: ""),
        ])
        let profiler = Profiler(appInfo: nil, antiCheatDB: db)
        XCTAssertEqual(profiler.profile(appid: 1, installDir: dir).verdict, .blocked, "denied, and no bootstrap to skip")
        let supported = profiler.profile(appid: 2, installDir: dir)
        XCTAssertEqual(supported.verdict, .needsTesting)
        XCTAssertFalse(supported.offlineOnly)
        XCTAssertTrue(supported.verdictReasons.contains { $0.contains("无法联机") }, "Proton support says nothing about macOS Wine")
        XCTAssertEqual(profiler.profile(appid: 4, installDir: dir).verdict, .needsTesting, "Broken on Proton is not a block")
        XCTAssertEqual(profiler.profile(appid: 3, installDir: dir).verdict, .needsTesting, "EAC files with no record")
        XCTAssertEqual(profiler.profile(appid: 5, installDir: dir).verdict, .blocked, "kernel anti-cheat named by AreWeAntiCheatYet")
        let bare = profiler.profile(appid: 6, installDir: dir).verdictReasons
        XCTAssertTrue(bare.contains("开发者不允许 反作弊 在 Wine/Proton 下运行（AreWeAntiCheatYet：Denied）"), "\(bare)")

        try write("mhyprot2.sys")
        XCTAssertEqual(profiler.profile(appid: 2, installDir: dir).verdict, .blocked, "kernel anti-cheat always blocks")
    }

    /// ELDEN RING shape: Steam launches EAC's bootstrap, which cannot run under macOS Wine.
    func testEasyAntiCheatBootstrapLaunchesTheGameOffline() throws {
        try write("Game/start_protected_game.exe", makePE(is64: true, imports: ["kernel32.dll"]))
        try write("Game/EasyAntiCheat/Settings.json", Data([0xEF, 0xBB, 0xBF]) + Data(#"{"productid": "x", "executable": "eldenring.exe"}"#.utf8))
        try write("Game/eldenring.exe", makePE(is64: true, imports: ["d3d12.dll", "steam_api64.dll"]))
        let info = try makeAppInfo(appid: 1245620, launch: [
            ["executable": "Game\\start_protected_game.exe", "arguments": "-windowed", "type": "default"],
        ])
        let db = AntiCheatDB(entries: [1245620: .init(name: "ER", status: "Denied", antiCheats: ["Easy Anti-Cheat"], dateChanged: "2024-01-19")])
        let p = Profiler(appInfo: info, antiCheatDB: db).profile(appid: 1245620, installDir: dir)

        XCTAssertEqual(p.launch, LaunchPlan(executable: "Game/eldenring.exe", arguments: ["-windowed"], workingDirectory: nil, bypassesAntiCheat: true))
        XCTAssertTrue(p.offlineOnly)
        XCTAssertEqual(p.analysis.mainExecutable?.lastPathComponent, "eldenring.exe")
        XCTAssertEqual(p.analysis.likelyAPIs.first, .d3d12)
        XCTAssertEqual(p.ladder.first?.renderer, .d3dMetal)
        XCTAssertEqual(p.verdict, .needsTesting, "a denial does not block the offline launch")
        XCTAssertTrue(p.verdictReasons.contains { $0.hasPrefix("仅限离线") })
        XCTAssertEqual(p.analysis.antiCheats.map(\.name), ["Easy Anti-Cheat"], "the anti-cheat is still reported")
    }

    func testBattlEyeBootstrapResolvesTheGameExecutable() throws {
        try write("DayZ_BE.exe", makePE(is64: true, imports: []))
        try write("DayZ_x64.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        try write("BattlEye/BEClient_x64.dll")
        XCTAssertEqual(LaunchPlan.resolving(executable: "DayZ_BE.exe", in: dir),
                       LaunchPlan(executable: "DayZ_x64.exe", arguments: [], workingDirectory: nil, bypassesAntiCheat: true))

        try write("bin/Arma3BattlEye.exe", makePE(is64: true, imports: []))
        try write("bin/BELauncher.ini", Data("[Launcher]\r\n32BitExe=arma3.exe\r\n64BitExe = arma3_x64.exe\r\n".utf8))
        try write("bin/arma3.exe", makePE(is64: false, imports: ["d3d11.dll"]))
        try write("bin/arma3_x64.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        XCTAssertEqual(LaunchPlan.resolving(executable: "bin\\arma3battleye.exe", in: dir).executable, "bin/arma3_x64.exe",
                       "64-bit target from BELauncher.ini, on-disk spelling")

        try write("Other_BE.exe", makePE(is64: true, imports: []))
        let missing = LaunchPlan.resolving(executable: "Other_BE.exe", in: dir)
        XCTAssertEqual(missing.executable, "Other_BE.exe", "no game behind it: keep the entry")
        XCTAssertFalse(missing.bypassesAntiCheat)
    }

    /// UE shape: the root exe only starts <Project>/Binaries/Win64/<Project>-Win64-Shipping.exe.
    func testUnrealRootStubTakesGraphicsFromShippingExecutable() throws {
        try write("Pal.exe", makePE(is64: false, imports: ["kernel32.dll", "shell32.dll"]))
        try write("Pal/Binaries/Win64/Pal-Win64-Shipping.exe", makePE(is64: true, imports: ["d3d11.dll"], delayImports: ["d3d12.dll"]))
        try write("Pal/Binaries/Win64/CrashReportClient.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        try write("Engine/Binaries/ThirdParty/x.dll", makePE(is64: true, imports: []))
        let a = GameAnalyzer.analyze(installDir: dir, executable: "Pal.exe")
        XCTAssertEqual(a.engine, .unreal)
        XCTAssertEqual(a.mainExecutable?.lastPathComponent, "Pal.exe", "the stub still forwards the command line")
        XCTAssertEqual(a.likelyAPIs, [.d3d12, .d3d11])
        XCTAssertFalse(a.is32Bit, "bitness comes from the shipping executable")
        XCTAssertNil(a.otherExecutables["pal/binaries/win64/pal-win64-shipping.exe"])
        let ladder = RendererLadder.build(for: a, settings: WineSettings())
        XCTAssertEqual(ladder.first?.renderer, .d3dMetal)
        XCTAssertTrue(ladder.contains { $0.renderer == .dxmt && $0.arguments == ["-dx11"] })
    }

    func testUnrealShippingExecutableIsFoundPastTheModuleCap() throws {
        try write("Pal.exe", makePE(is64: false, imports: ["kernel32.dll"]))
        for i in 0..<(GameAnalyzer.maxModules + 10) { try write("Engine/Plugins/p\(i).dll") }
        try write("Pal/Binaries/Win64/Pal-Win64-Shipping.exe", makePE(is64: true, imports: ["d3d12.dll"]))
        let a = GameAnalyzer.analyze(installDir: dir, executable: "Pal.exe")
        XCTAssertEqual(a.likelyAPIs.first, .d3d12)
        XCTAssertFalse(a.is32Bit)
    }

    /// A separate exe beside the EasyAntiCheat folder is its own launch, not a bootstrap.
    func testEasyAntiCheatRedirectOnlyAppliesToTheBootstrap() throws {
        try write("Game/EasyAntiCheat/Settings.json", Data(#"{"executable": "mp.exe"}"#.utf8))
        try write("Game/mp.exe", makePE(is64: true, imports: ["d3d12.dll"]))
        try write("Game/sp.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        try write("Game/start_protected_game.exe", makePE(is64: true, imports: ["kernel32.dll"]))
        let sp = LaunchPlan.resolving(executable: "Game/sp.exe", in: dir)
        XCTAssertEqual(sp.executable, "Game/sp.exe")
        XCTAssertFalse(sp.bypassesAntiCheat)
        XCTAssertEqual(LaunchPlan.resolving(executable: "Game/start_protected_game.exe", in: dir).executable, "Game/mp.exe")
    }

    func testAntiCheatNamesFromDifferentSourcesAreOneProduct() {
        XCTAssertTrue(Profiler.sameAntiCheat("EA Javelin", "Javelin"))
        XCTAssertTrue(Profiler.sameAntiCheat("nProtect GameGuard", "GameGuard"))
        XCTAssertTrue(Profiler.sameAntiCheat("Easy Anti-Cheat", "Easy Anti-Cheat (EOS)"))
        XCTAssertFalse(Profiler.sameAntiCheat("Easy Anti-Cheat", "BattlEye"))
        XCTAssertFalse(Profiler.sameAntiCheat("EAC", "Easy Anti-Cheat Plus"), "short keys match only exactly")
    }

    func testMainExecutableImportsOutrankBundledMiddleware() throws {
        try write("game.exe", makePE(is64: true, imports: ["d3d12.dll"]))
        try write("amd_fidelityfx_vk.dll", makePE(is64: true, imports: ["vulkan-1.dll"]))
        XCTAssertEqual(GameAnalyzer.analyze(installDir: dir, executable: "game.exe").likelyAPIs, [.d3d12, .vulkan])

        try FileManager.default.removeItem(at: dir.appendingPathComponent("amd_fidelityfx_vk.dll"))
        try write("game.exe", makePE(is64: true, imports: ["unityplayer.dll"]))
        try write("UnityPlayer.dll", makePE(is64: true, imports: ["opengl32.dll", "d3d11.dll"]))
        XCTAssertEqual(GameAnalyzer.analyze(installDir: dir, executable: "game.exe").likelyAPIs.first, .d3d11,
                       "equally strong evidence: D3D11 before OpenGL")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("UnityPlayer.dll"))
        try write("game.exe", makePE(is64: true, imports: ["vulkan-1.dll"]))
        try write("overlay.dll", makePE(is64: true, imports: ["d3d11.dll"]))
        XCTAssertEqual(GameAnalyzer.analyze(installDir: dir, executable: "game.exe").likelyAPIs, [.vulkan, .d3d11])
    }

    /// HL2 episode shape: the entry's arguments and working directory are part of the launch.
    func testLaunchEntryArgumentsAndWorkingDirectoryCarryThrough() throws {
        try write("hl2.exe", makePE(is64: false, imports: ["d3d9.dll"]))
        try write("bin/hl2_dx12.exe", makePE(is64: true, imports: ["d3d12.dll"]))
        try write("ep2/gameinfo.txt")
        let info = try makeAppInfo(appid: 420, launch: [
            ["executable": "hl2.exe", "arguments": "-game ep2 -name \"A B\"", "workingdir": "ep2", "type": "default"],
            ["executable": "bin\\hl2_dx12.exe", "arguments": "-game ep2", "type": "option1"],
            ["executable": "hl2.exe", "arguments": "-vr", "type": "vr"],
        ])
        let p = Profiler(appInfo: info, antiCheatDB: nil).profile(appid: 420, installDir: dir)
        let main = try XCTUnwrap(p.launch)
        XCTAssertEqual(main.arguments, ["-game", "ep2", "-name", "A B"])
        XCTAssertEqual(main.workingDirectory, "ep2")
        XCTAssertEqual(main.workingDirectoryURL(in: p.analysis.installDir).lastPathComponent, "ep2")
        XCTAssertEqual(p.plan(for: p.ladder.first), main)

        let alternate = try XCTUnwrap(p.ladder.first { $0.executable != nil }, "a 64-bit D3D12 build behind a 32-bit default")
        XCTAssertEqual(alternate.renderer, .d3dMetal)
        XCTAssertEqual(p.plan(for: alternate)?.executable, "bin/hl2_dx12.exe")
        XCTAssertEqual(p.plan(for: alternate)?.arguments, ["-game", "ep2"])
        XCTAssertEqual(p.plan(for: alternate)?.workingDirectoryURL(in: p.analysis.installDir).lastPathComponent, "bin",
                       "no working directory: the executable's folder")
        XCTAssertEqual(p.metadata?.windowsLaunchEntries.count, 2, "the VR entry is not a player launch")
    }

    func testMainExecutableRelativeIsCanonical() throws {
        try write("bin/Game.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        let a = GameAnalyzer.analyze(installDir: link, executable: "\\BIN\\game.EXE")
        XCTAssertEqual(a.mainExecutableRelative, "bin/Game.exe", "through the symlink, in on-disk case")
        XCTAssertEqual(a.installDir.appendingPathComponent(a.mainExecutableRelative!).path, a.mainExecutable?.path)
    }

    func testPlayerLaunchTypes() {
        func entry(_ type: String) -> AppMetadata.LaunchEntry {
            .init(index: "0", executable: "a.exe", arguments: "", workingDir: "", osList: [], osArch: "", type: type, description: "", betaKey: "")
        }
        XCTAssertEqual(["", "default", "Option2", "none", "vr", "othervr", "openvr", "editor", "server", "manual"].map { entry($0).isPlayableWindowsEntry },
                       [true, true, true, false, false, false, false, false, false, false])
    }

    func testExecutableGuessSkipsInstallers() throws {
        try write("unins000.exe", makePE(is64: false, imports: []) + Data(count: 4096))
        try write("Game.exe", makePE(is64: true, imports: ["d3d11.dll"]))
        XCTAssertEqual(Profiler(appInfo: nil, antiCheatDB: nil).guessExecutable(in: dir), "Game.exe")
    }
}

final class CompatTests: XCTestCase {
    func testSplitFlagsHonoursEscapedCommas() {
        XCTAssertEqual(ValveCompatManifest.splitFlags("noesync,cmdlineappend:-a\\,b, nofsync"),
                       ["noesync", "cmdlineappend:-a,b", "nofsync"])
        XCTAssertEqual(ValveCompatManifest.splitFlags("none"), [])
    }

    func testQuirkTranslationRespectsEngine() {
        let flags = ["noesync", "forcelgadd", "heapdelayfree", "cmdlineappend:-dx11", "usenativexinput13", "seccomp", "mystery"]
        let (s, r) = QuirkTranslator.translate(flags, engine: .crossOverBased)
        XCTAssertFalse(s.useMsync)
        XCTAssertEqual(s.env["WINE_LARGE_ADDRESS_AWARE"], "1")
        XCTAssertNil(s.env["WINE_HEAP_DELAY_FREE"], "Proton-only patch is not claimed on a CrossOver engine")
        XCTAssertEqual(s.extraArguments, ["-dx11"])
        XCTAssertEqual(s.dllOverridesString, "xinput1_3=n,b")
        XCTAssertEqual(r.map(\.status), [.applied, .applied, .engineUnsupported, .applied, .applied, .notApplicable, .unknown])

        let (p, _) = QuirkTranslator.translate(["heapdelayfree"], engine: EngineCapabilities(stagingEnv: true, protonPatches: true))
        XCTAssertEqual(p.env["WINE_HEAP_DELAY_FREE"], "1")
    }

    func testAntiCheatDBDecodesSteamIDs() throws {
        let json = """
        [{"name":"A","status":"Denied","anticheats":["BattlEye"],"storeIds":{"steam":"236390"},"dateChanged":"2024-12-27T00:00:00Z"},
         {"name":"B","status":"Broken","anticheats":["EAC"],"storeIds":{"epic":{"namespace":"x","slug":"y"}}}]
        """
        let db = try AntiCheatDB(data: Data(json.utf8))
        XCTAssertEqual(db.entries.count, 1)
        XCTAssertEqual(db[236390]?.antiCheats, ["BattlEye"])
    }
}
