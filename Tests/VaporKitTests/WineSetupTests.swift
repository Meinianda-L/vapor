import XCTest
@testable import VaporKit

final class WineSetupTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vapor-wine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fake trees

    @discardableResult
    private func write(_ text: String, _ path: String, in base: URL? = nil, executable: Bool = false) throws -> URL {
        let url = (base ?? tmp).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// A Wine root whose bin/wine prints `version` for --version.
    @discardableResult
    private func fakeEngine(_ path: String, version: String = "wine-9.9 (Fake)", wine64Only: Bool = false,
                            wineserver: Bool = true) throws -> URL {
        let root = tmp.appendingPathComponent(path, isDirectory: true)
        try write("#!/bin/sh\necho '\(version)'\n", wine64Only ? "bin/wine64" : "bin/wine", in: root, executable: true)
        if wineserver { try write("#!/bin/sh\nexit 0\n", "bin/wineserver", in: root, executable: true) }
        for (file, text) in [("x86_64-windows/d3d11.dll", "wine-d3d11-64"), ("x86_64-windows/dxgi.dll", "wine-dxgi-64"),
                             ("x86_64-windows/kernel32.dll", "kernel32"), ("i386-windows/d3d11.dll", "wine-d3d11-32"),
                             ("x86_64-unix/ntdll.so", "ntdll")] {
            try write(text, "lib/wine/\(file)", in: root)
        }
        return root
    }

    private func fakeDXMT(at root: URL, version: String? = nil, wineSubdir: Bool = false) throws {
        let prefix = wineSubdir ? "wine/" : ""
        for file in ["x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll", "x86_64-windows/winemetal.dll",
                     "x86_64-unix/winemetal.so", "i386-windows/d3d11.dll", "i386-windows/winemetal.dll"] {
            try write("dxmt-\(version ?? "x")-\(file)", prefix + file, in: root)
        }
        try write("MIT", "LICENSE", in: root)
        if let version { try write(version + "\n", "version", in: root) }
    }

    private func fakeD3DMetalFramework(in external: URL, version: String = "3.0") throws {
        let fw = external.appendingPathComponent("D3DMetal.framework")
        try write("binary", "Versions/A/D3DMetal", in: fw)
        try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
            """, "Versions/A/Resources/Info.plist", in: fw)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("D3DMetal").path, withDestinationPath: "Versions/Current/D3DMetal")
        try write("shared", "libd3dshared.dylib", in: external)
    }

    private func searchPaths() -> EngineCatalog.SearchPaths {
        EngineCatalog.SearchPaths(home: tmp.appendingPathComponent("home"), applications: [tmp.appendingPathComponent("Applications")],
                                  homebrewBins: [tmp.appendingPathComponent("brew/bin")],
                                  vapor: VaporLocations(root: tmp.appendingPathComponent("home/Library/Application Support/Vapor")))
    }

    // MARK: - Discovery

    func testDiscoveryFindsEverySourceAndDeduplicates() async throws {
        let support = "home/Library/Application Support"
        try fakeEngine("\(support)/heroic/tools/wine/Wine-10.0-Sikarugir", version: "wine-10.0 (Sikarugir)")
        try write("partial", "\(support)/heroic/tools/wine/wine-staging-11.18-osx64.tar.xz.$$13$PART")
        try fakeEngine("\(support)/Sikarugir/Engines/WS12WineSikarugir10.0_6/wswine.bundle")
        try write("xz", "\(support)/Sikarugir/Engines/WS12WineSikarugir10.0_6.tar.xz")
        try fakeEngine("\(support)/Vapor/Engines/wine-devel-11.21-osx64/Wine Devel.app/Contents/Resources/wine", version: "wine-11.21")
        try fakeEngine("\(support)/Vapor/Engines/Variants/x-1/dxmt")
        let gptk = try fakeEngine("Applications/Game Porting Toolkit.app/Contents/Resources/wine", version: "wine-7.7 (GPTK)", wine64Only: true)
        try fakeD3DMetalFramework(in: gptk.appendingPathComponent("lib/external"))
        try FileManager.default.createDirectory(at: gptk.appendingPathComponent("lib/wine/x86_32on64-unix"), withIntermediateDirectories: true)
        try fakeEngine("Applications/CrossOver.app/Contents/SharedSupport/CrossOver")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("brew/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("brew/bin/wine64"), withDestinationURL: gptk.appendingPathComponent("bin/wine64"))

        let engines = await EngineCatalog.discover(in: searchPaths())
        XCTAssertEqual(engines.map(\.source), [.vapor, .heroic, .sikarugir, .gptk, .crossover], "\(engines.map(\.root.path))")
        XCTAssertFalse(engines.contains { $0.root.path.contains("/Variants/") })

        let byName = Dictionary(uniqueKeysWithValues: engines.map { ($0.name, $0) })
        let heroic = try XCTUnwrap(byName["Wine-10.0-Sikarugir"])
        XCTAssertEqual(heroic.version, "wine-10.0 (Sikarugir)")
        XCTAssertTrue(heroic.usable)
        XCTAssertTrue(heroic.capabilities.supports32Bit && heroic.capabilities.wow64)
        XCTAssertFalse(heroic.capabilities.hasWineMetal || heroic.capabilities.hasD3DMetal)

        let sikarugir = try XCTUnwrap(byName["WS12WineSikarugir10.0_6"])
        XCTAssertEqual(sikarugir.root.lastPathComponent, "wswine.bundle")
        XCTAssertEqual(byName["wine-devel-11.21-osx64"]?.root.lastPathComponent, "wine")

        let g = try XCTUnwrap(engines.first { $0.source == .gptk })
        XCTAssertEqual(g.name, "Game Porting Toolkit")
        XCTAssertEqual(g.wine.lastPathComponent, "wine64")
        XCTAssertTrue(g.capabilities.hasD3DMetal)
        XCTAssertFalse(g.capabilities.wow64)
        XCTAssertFalse(g.usable)

        let cx = try XCTUnwrap(engines.first { $0.source == .crossover })
        XCTAssertFalse(cx.usable)
        XCTAssertNotNil(cx.unusableReason)
    }

    func testIdentifierIsStableAndFilesystemSafe() {
        let root = URL(fileURLWithPath: "/x/Wine Devel.app/Contents/Resources/wine")
        let id = WineEngine.identifier(forRoot: root)
        XCTAssertEqual(id, WineEngine.identifier(forRoot: root))
        XCTAssertTrue(id.hasPrefix("Wine-Devel-"), id)
        XCTAssertFalse(id.contains("/") || id.contains(" "))
        XCTAssertNotEqual(id, WineEngine.identifier(forRoot: URL(fileURLWithPath: "/y/Wine Devel.app/Contents/Resources/wine")))
    }

    // MARK: - Packs

    func testPackDiscoveryReadsEveryLayout() throws {
        let tools = "home/Library/Application Support/heroic/tools"
        try fakeDXMT(at: tmp.appendingPathComponent("\(tools)/dxmt/dxmt-v0.80-builtin"))
        try write("dxmt-v0.80-builtin", "\(tools)/dxmt/latest_dxmt")
        let dxvk = tmp.appendingPathComponent("\(tools)/dxvk-macOS/dxvk-macOS-async-v1.10.3-20230507-repack")
        try write("x64", "x64/d3d11.dll", in: dxvk)
        try write("x32", "x32/d3d11.dll", in: dxvk)
        try write("conf", "dxvk.conf", in: dxvk)
        let engineRoot = try fakeEngine("home/Library/Application Support/heroic/tools/wine/Wine-10.0-Sikarugir")
        try fakeDXMT(at: engineRoot.appendingPathComponent("lib/renderer/dxmt"), version: "v0.80-244-g7c8dee1", wineSubdir: true)
        let gptk = try fakeEngine("Applications/Game Porting Toolkit.app/Contents/Resources/wine", wine64Only: true)
        try fakeD3DMetalFramework(in: gptk.appendingPathComponent("lib/external"), version: "3.0")
        try write("dm-so", "lib/wine/x86_64-unix/d3d11.so", in: gptk)
        try write("dm-so", "lib/wine/x86_64-unix/nvngx.so", in: gptk)
        try write("dm-dll", "lib/wine/x86_64-windows/nvngx-on-metalfx.dll", in: gptk)

        let engines = EngineCatalog.candidates(in: searchPaths())
        let packs = RendererPacks.discover(in: searchPaths(), engines: engines)
        XCTAssertEqual(packs.map(\.kind), [.dxmt, .dxvk, .d3dmetal, .dxmt], "\(packs.map(\.root.path))")

        let heroicDXMT = packs[0]
        XCTAssertEqual(heroicDXMT.version, "v0.80")
        XCTAssertEqual(heroicDXMT.origin, .heroic)
        XCTAssertFalse(heroicDXMT.files.contains { $0.destination.contains("LICENSE") })
        XCTAssertTrue(heroicDXMT.files.contains { $0.destination == "lib/wine/x86_64-unix/winemetal.so" })

        let plainDXVK = packs[1]
        XCTAssertEqual(plainDXVK.version, "v1.10.3-20230507-repack")
        XCTAssertEqual(Set(plainDXVK.files.map(\.destination)), ["lib/wine/x86_64-windows/d3d11.dll", "lib/wine/i386-windows/d3d11.dll"])

        let d3dmetal = packs[2]
        XCTAssertEqual(d3dmetal.version, "3.0")
        XCTAssertEqual(d3dmetal.origin, .gptk)
        XCTAssertEqual(Set(d3dmetal.files.map(\.destination)), [
            "lib/wine/x86_64-unix/d3d11.so", "lib/wine/x86_64-unix/nvngx.so", "lib/wine/x86_64-windows/d3d11.dll",
            "lib/wine/x86_64-windows/dxgi.dll", "lib/external/D3DMetal.framework", "lib/external/libd3dshared.dylib",
        ], "GPTK's own Wine modules and its 32-bit d3d11 stay out")

        let bundled = packs[3]
        XCTAssertEqual(bundled.version, "v0.80-244-g7c8dee1")
        XCTAssertEqual(bundled.origin, .engine("Wine-10.0-Sikarugir"))

        let heroicEngine = try XCTUnwrap(engines.first { $0.source == .heroic })
        XCTAssertEqual(RendererPacks.preferred(.dxmt, for: heroicEngine, among: packs)?.version, "v0.80-244-g7c8dee1")
        let other = try XCTUnwrap(WineEngine(root: try fakeEngine("other"), source: .vapor))
        XCTAssertEqual(RendererPacks.preferred(.dxmt, for: other, among: packs)?.version, "v0.80")
        XCTAssertNil(RendererPacks.preferred(.dxvk, for: other, among: packs.filter { $0.kind != .dxvk }))
    }

    func testDetectKind() throws {
        let dxmt = tmp.appendingPathComponent("a")
        try fakeDXMT(at: dxmt)
        XCTAssertEqual(RendererPack.detectKind(at: dxmt), .dxmt)
        let dxvk = tmp.appendingPathComponent("b")
        try write("x", "x86_64-windows/d3d11.dll", in: dxvk)
        XCTAssertEqual(RendererPack.detectKind(at: dxvk), .dxvk)
        XCTAssertNil(RendererPack.detectKind(at: tmp.appendingPathComponent("missing")))
    }

    // MARK: - Variants

    func testVariantOverlayIsCorrectAndIdempotent() async throws {
        let baseRoot = try fakeEngine("base")
        try FileManager.default.createSymbolicLink(atPath: baseRoot.appendingPathComponent("lib/libfoo.dylib").path, withDestinationPath: "libfoo.1.dylib")
        let base = try XCTUnwrap(WineEngine(root: baseRoot, source: .vapor))
        let packRoot = tmp.appendingPathComponent("packs/dxmt/v1")
        try fakeDXMT(at: packRoot, version: "v1")
        let pack = try XCTUnwrap(RendererPack(kind: .dxmt, root: packRoot, origin: .vapor))
        let builder = VariantBuilder(outputRoot: tmp.appendingPathComponent("variants"))

        guard case let .built(dir, _) = try await builder.build(.dxmt, from: base, pack: pack) else { return XCTFail("not built") }
        XCTAssertEqual(dir, builder.directory(for: base, renderer: .dxmt))
        XCTAssertEqual(read(dir.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "dxmt-v1-x86_64-windows/d3d11.dll")
        XCTAssertEqual(read(dir.appendingPathComponent("lib/wine/i386-windows/d3d11.dll")), "dxmt-v1-i386-windows/d3d11.dll")
        XCTAssertEqual(read(dir.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")), "dxmt-v1-x86_64-unix/winemetal.so")
        XCTAssertEqual(read(dir.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll")), "kernel32")
        XCTAssertNil(read(dir.appendingPathComponent("LICENSE")))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("lib/libfoo.dylib").path), "libfoo.1.dylib")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("bin/wine").path))
        XCTAssertEqual(read(baseRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "wine-d3d11-64", "base untouched")
        let marker = try XCTUnwrap(builder.existingMarker(at: dir))
        XCTAssertEqual(marker.packVersion, "v1")
        XCTAssertEqual(marker.renderer, "dxmt")
        XCTAssertTrue(builder.isUpToDate(.dxmt, engine: base, pack: pack))

        let again = try await builder.build(.dxmt, from: base, pack: pack)
        XCTAssertEqual(again, .upToDate(dir))

        let newRoot = tmp.appendingPathComponent("packs/dxmt/v2")
        try fakeDXMT(at: newRoot, version: "v2")
        let newer = try XCTUnwrap(RendererPack(kind: .dxmt, root: newRoot, origin: .vapor))
        XCTAssertFalse(builder.isUpToDate(.dxmt, engine: base, pack: newer))
        guard case .built = try await builder.build(.dxmt, from: base, pack: newer) else { return XCTFail("not rebuilt") }
        XCTAssertEqual(read(dir.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "dxmt-v2-x86_64-windows/d3d11.dll")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])

        do {
            _ = try await builder.build(.dxvk, from: base, pack: newer)
            XCTFail("dxvk built from a dxmt pack")
        } catch let error as WineSetupError {
            XCTAssertEqual(error, .noPack(.dxvk))
        }
    }

    func testBuildAllCoversEveryRendererAndSkipsMissingPacks() async throws {
        let base = try XCTUnwrap(WineEngine(root: try fakeEngine("base"), source: .vapor))
        let external = tmp.appendingPathComponent("dm/lib/external")
        try fakeD3DMetalFramework(in: external)
        try write("so", "dm/lib/wine/x86_64-unix/d3d11.so")
        try write("dll", "dm/lib/wine/x86_64-windows/d3d11.dll")
        let d3dmetal = try XCTUnwrap(RendererPack(kind: .d3dmetal, root: tmp.appendingPathComponent("dm"), origin: .gptk))
        let builder = VariantBuilder(outputRoot: tmp.appendingPathComponent("variants"))

        let results = await builder.buildAll(from: base, packs: [d3dmetal])
        guard case .skipped = results[.dxmt], case .skipped = results[.dxvk] else { return XCTFail("\(results)") }
        guard case let .built(wined3d, _) = results[.wined3d], case let .built(dm, _) = results[.d3dmetal] else { return XCTFail("\(results)") }
        XCTAssertEqual(read(wined3d.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "wine-d3d11-64")
        XCTAssertEqual(read(dm.appendingPathComponent("lib/wine/x86_64-unix/d3d11.so")), "so")
        let fw = dm.appendingPathComponent("lib/external/D3DMetal.framework")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path), "A")
        XCTAssertEqual(read(fw.appendingPathComponent("D3DMetal")), "binary")
    }

    func testUnusableEngineIsRefused() async throws {
        let engine = try XCTUnwrap(WineEngine(root: try fakeEngine("noserver", wineserver: false), source: .vapor))
        XCTAssertFalse(engine.usable)
        do {
            _ = try await VariantBuilder(outputRoot: tmp.appendingPathComponent("v")).build(.wined3d, from: engine, pack: nil)
            XCTFail("built from an engine without wineserver")
        } catch is WineSetupError {}
    }

    func testEngineVariantLookupPrefersVaporBuild() throws {
        let locations = VaporLocations(root: tmp.appendingPathComponent("vapor"))
        let base = try fakeEngine("base")
        XCTAssertNil(EngineVariants.directory(for: .dxmt, base: base, locations: locations), "no legacy fallback for another engine")
        let built = locations.variants.appendingPathComponent(WineEngine.identifier(forRoot: base)).appendingPathComponent("dxvk")
        try write("#!/bin/sh\n", "bin/wine", in: built, executable: true)
        XCTAssertEqual(EngineVariants.directory(for: .dxvkMoltenVK, base: base, locations: locations)?.path, built.path)
        XCTAssertEqual(EngineVariants.directory(for: .dxvkKosmicKrisp, base: base, locations: locations)?.path, built.path)
    }

    // MARK: - Config

    func testConfigRoundTrip() throws {
        let url = tmp.appendingPathComponent("sub/config.json")
        XCTAssertEqual(VaporConfig.load(from: url), VaporConfig())
        let config = VaporConfig(engineRoot: "/e/Wine Devel.app/Contents/Resources/wine", steamPrefix: "/p/Steam")
        try config.save(to: url)
        XCTAssertEqual(VaporConfig.load(from: url), config)
        XCTAssertEqual(VaporConfig.load(from: url).engineURL?.lastPathComponent, "wine")
        try #"{"steamPrefix": "/q", "futureKey": 3}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VaporConfig.load(from: url), VaporConfig(engineRoot: nil, steamPrefix: "/q"))
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VaporConfig.load(from: url), VaporConfig())
    }

    func testDetectDefaultHonoursConfig() throws {
        let home = tmp.appendingPathComponent("vapor")
        let engine = try fakeEngine("engine")
        let prefix = tmp.appendingPathComponent("prefix")
        try write("exe", "drive_c/Program Files (x86)/Steam/steam.exe", in: prefix)
        try VaporConfig(engineRoot: engine.path, steamPrefix: prefix.path).save(to: VaporLocations(root: home).config)
        let previous = ProcessInfo.processInfo.environment["VAPOR_HOME"]
        setenv("VAPOR_HOME", home.path, 1)
        defer { if let previous { setenv("VAPOR_HOME", previous, 1) } else { unsetenv("VAPOR_HOME") } }
        let steam = try XCTUnwrap(WindowsSteam.detectDefault())
        XCTAssertEqual(steam.engine.path, engine.path)
        XCTAssertEqual(steam.prefix.path, prefix.path)
    }

    // MARK: - GitHub releases

    func testParseReleases() throws {
        let json = """
        [
          {"tag_name": "v1.10.3-20230507-repack", "draft": false, "prerelease": false, "published_at": "2024-07-23T13:51:20Z",
           "assets": [
             {"name": "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz", "size": 2785833,
              "browser_download_url": "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
              "digest": "sha256:810B1E5CAF8CE975B784FAE866A130AD23FA0EA233B0E5609CBC4A45F3EF6F00", "updated_at": "2026-02-19T00:00:00Z"},
             {"name": "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz", "size": 2793443,
              "browser_download_url": "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
              "digest": null, "updated_at": "2024-07-23T13:51:20Z"}
           ]},
          {"tag_name": "v1.10.3-20230402", "draft": false, "prerelease": false, "published_at": "2023-04-02T15:12:49Z",
           "assets": [
             {"name": "dxvk-macOS-async-v1.10.3-20230402-CrossOver.tar.gz", "size": 9395238,
              "browser_download_url": "https://example.invalid/a.tar.gz", "updated_at": "2023-04-02T15:12:49Z"},
             {"name": "dxvk-macOS-async-v1.10.3-20230402.tar.gz", "size": 7675520,
              "browser_download_url": "https://example.invalid/b.tar.gz", "updated_at": "2023-04-02T15:12:49Z"}
           ]},
          {"tag_name": "draft", "draft": true, "assets": [
             {"name": "dxvk-macOS-draft.tar.gz", "size": 1, "browser_download_url": "https://example.invalid/c.tar.gz"}]}
        ]
        """
        let dxvk = try EngineDownloads.parseReleases(Data(json.utf8), repository: "Gcenx/DXVK-macOS")
        XCTAssertEqual(dxvk.map(\.name), ["dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz", "dxvk-macOS-async-v1.10.3-20230402.tar.gz"])
        XCTAssertEqual(dxvk[0].kind, .pack(.dxvk))
        XCTAssertEqual(dxvk[0].size, 2_785_833)
        XCTAssertEqual(dxvk[0].sha256, "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00")
        XCTAssertEqual(dxvk[0].installName, "v1.10.3-20230507-repack")
        XCTAssertNil(dxvk[1].sha256)

        let engines = """
        [{"tag_name": "v1.0", "prerelease": false, "published_at": "2024-10-03T20:04:52Z", "assets": [
          {"name": "WS12WineSikarugir10.0_6.tar.xz", "size": 166304096, "browser_download_url": "https://example.invalid/6.tar.xz",
           "updated_at": "2026-04-10T22:44:58Z"},
          {"name": "WS12WineSikarugir10.0_8.tar.xz", "size": 166321980, "browser_download_url": "https://example.invalid/8.tar.xz",
           "updated_at": "2026-10-01T23:13:53Z"},
          {"name": "WS11WineCX32Bit21.2.0.tar.xz", "size": 107930956, "browser_download_url": "https://example.invalid/32.tar.xz",
           "updated_at": "2025-08-10T01:29:11Z"},
          {"name": "README.md", "size": 10, "browser_download_url": "https://example.invalid/readme"}
        ]}]
        """
        let ws = try EngineDownloads.parseReleases(Data(engines.utf8), repository: "Sikarugir-App/Engines")
        XCTAssertEqual(ws.map(\.name), ["WS12WineSikarugir10.0_8.tar.xz", "WS12WineSikarugir10.0_6.tar.xz"], "newest asset first")
        XCTAssertEqual(ws[0].kind, .engine)
        XCTAssertEqual(ws[0].installName, "WS12WineSikarugir10.0_8")

        XCTAssertTrue(EngineDownloads.accepts("dxmt-v0.80-builtin.tar.gz", repository: "3Shain/dxmt"))
        XCTAssertFalse(EngineDownloads.accepts("dxmt-v0.80.tar.gz", repository: "3Shain/dxmt"))
        XCTAssertTrue(EngineDownloads.accepts("wine-devel-11.21-osx64.tar.xz", repository: "Gcenx/macOS_Wine_builds"))
        XCTAssertThrowsError(try EngineDownloads.parseReleases(Data(#"{"message": "API rate limit exceeded"}"#.utf8), repository: "3Shain/dxmt"))
    }

    // MARK: - Installing archives

    private func tarball(_ dir: URL, top: String, to archive: URL, flag: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = [flag, archive.path, "-C", dir.path, top]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testInstallArchivesUnwrapValidateAndClean() async throws {
        let locations = VaporLocations(root: tmp.appendingPathComponent("vapor"))
        let downloads = EngineDownloads(locations: locations)

        let src = tmp.appendingPathComponent("src")
        try fakeDXMT(at: src.appendingPathComponent("v0.80"))
        let packArchive = tmp.appendingPathComponent("dxmt-v0.80-builtin.tar.gz")
        try tarball(src, top: "v0.80", to: packArchive, flag: "-czf")
        let item = try await downloads.install(archive: packArchive)
        guard case let .pack(pack) = item else { return XCTFail("\(item)") }
        XCTAssertEqual(pack.kind, .dxmt)
        XCTAssertEqual(pack.version, "v0.80")
        XCTAssertEqual(FileOps.canonicalPath(pack.root), FileOps.canonicalPath(locations.packs(.dxmt).appendingPathComponent("v0.80")))

        let engineSrc = tmp.appendingPathComponent("esrc")
        try FileManager.default.createDirectory(at: engineSrc, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try fakeEngine("tmp-engine"), to: engineSrc.appendingPathComponent("wswine.bundle"))
        let engineArchive = tmp.appendingPathComponent("WS12WineFake1.0.tar.xz")
        try tarball(engineSrc, top: "wswine.bundle", to: engineArchive, flag: "-cJf")
        let installed = try await downloads.install(archive: engineArchive, kind: .engine)
        guard case let .engine(engine) = installed else { return XCTFail("\(installed)") }
        XCTAssertEqual(engine.root, locations.engines.appendingPathComponent("WS12WineFake1.0", isDirectory: true))
        XCTAssertTrue(engine.usable)
        let found = EngineCatalog.candidates(in: EngineCatalog.SearchPaths(home: tmp.appendingPathComponent("nohome"), applications: [],
                                                                            homebrewBins: [], vapor: locations))
        XCTAssertEqual(found.map(\.name), ["WS12WineFake1.0"])

        let junkDir = tmp.appendingPathComponent("junk")
        try write("hello", "stuff/readme.txt", in: junkDir)
        let junk = tmp.appendingPathComponent("junk.tar.gz")
        try tarball(junkDir, top: "stuff", to: junk, flag: "-czf")
        do {
            _ = try await downloads.install(archive: junk)
            XCTFail("installed an archive with no engine or pack")
        } catch let error as WineSetupError {
            XCTAssertEqual(error, .invalidEngine("junk"))
        }
        do {
            _ = try await downloads.install(archive: tmp.appendingPathComponent("missing.tar.xz"))
            XCTFail("extracted a missing archive")
        } catch let error as WineSetupError {
            guard case .extractFailed = error else { return XCTFail("\(error)") }
        }
        let hidden = try FileManager.default.contentsOfDirectory(atPath: locations.root.path).filter { $0.hasPrefix(".extract") }
        XCTAssertEqual(hidden, [], "staging folders removed")
    }

    func testFetchCopiesWithProgress() async throws {
        let source = try write(String(repeating: "x", count: 300_000), "payload.bin")
        let dest = tmp.appendingPathComponent("out/payload.bin")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seen = Counter()
        try await EngineDownloads(locations: VaporLocations(root: tmp)).fetch(source, to: dest) { received, _ in seen.set(received) }
        XCTAssertEqual(try Data(contentsOf: dest).count, 300_000)
        XCTAssertEqual(seen.value, 300_000)
        XCTAssertEqual(try EngineDownloads.sha256(of: source), try EngineDownloads.sha256(of: dest))
    }

    // MARK: - Processes and prefix setup

    func testProcessRunnerTimeoutAndCancel() async throws {
        let start = Date()
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.3)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)

        let echo = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hi"])
        XCTAssertEqual(echo.output, "hi\n")

        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("not cancelled")
        } catch is CancellationError {}
    }

    func testPrefixSetupPiecesWithoutWine() async throws {
        let engine = try fakeEngine("engine")
        let prefix = tmp.appendingPathComponent("Prefixes/Steam")
        let setup = PrefixSetup(engine: engine, prefix: prefix, locations: VaporLocations(root: tmp))
        XCTAssertEqual(setup.steamExecutable.path, prefix.path + "/drive_c/Program Files (x86)/Steam/steam.exe")
        XCTAssertFalse(setup.isSteamInstalled)
        let env = setup.environment
        XCTAssertEqual(env["WINEPREFIX"], prefix.path)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d;mscoree=d;mshtml=d")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(PrefixSetup(engine: engine, locations: VaporLocations(root: tmp)).prefix, VaporLocations(root: tmp).defaultSteamPrefix)

        // Steam already there: nothing runs.
        try write("exe", "drive_c/Program Files (x86)/Steam/steam.exe", in: prefix)
        let exe = try await setup.run()
        XCTAssertEqual(exe, setup.steamExecutable)

        do {
            _ = try await PrefixSetup(engine: tmp.appendingPathComponent("nothing"), prefix: prefix).run()
            XCTFail("ran without an engine")
        } catch let error as WineSetupError {
            XCTAssertEqual(error, .invalidEngine("nothing"))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64 = 0
    func set(_ v: Int64) { lock.lock(); _value = v; lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return _value }
}
