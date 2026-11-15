import Foundation

public enum GraphicsAPI: String, Sendable, CaseIterable, Comparable {
    case ddraw, d3d8, d3d9, d3d10, d3d11, d3d12, opengl, vulkan

    /// DLLs whose presence means the API is used.
    var modules: [String] {
        switch self {
        case .ddraw: return ["ddraw.dll"]
        case .d3d8: return ["d3d8.dll"]
        case .d3d9: return ["d3d9.dll"]
        case .d3d10: return ["d3d10.dll", "d3d10_1.dll", "d3d10core.dll"]
        case .d3d11: return ["d3d11.dll"]
        case .d3d12: return ["d3d12.dll"]
        case .opengl: return ["opengl32.dll"]
        case .vulkan: return ["vulkan-1.dll"]
        }
    }

    /// Tie-break between APIs with equally strong evidence: a game linking several
    /// usually renders with the newest D3D it ships, and with Vulkan/GL before legacy D3D.
    var preference: Int {
        switch self {
        case .d3d12: return 7
        case .d3d11: return 6
        case .d3d10: return 5
        case .d3d9: return 4
        case .vulkan: return 3
        case .opengl: return 2
        case .d3d8: return 1
        case .ddraw: return 0
        }
    }

    public static func < (a: GraphicsAPI, b: GraphicsAPI) -> Bool { a.preference < b.preference }
}

public enum Engine: String, Sendable { case source, source2, unity, unreal, unknown }

public struct AntiCheat: Sendable, Equatable, Hashable {
    public let name: String
    /// Kernel-level anti-cheats never run under Wine.
    public let kernelLevel: Bool
    public let evidence: String
}

public struct Evidence: Sendable, Equatable {
    /// Found in a module's import table (the module links against it).
    public var strong: [String] = []
    /// Found only as a string (likely LoadLibrary at runtime).
    public var weak: [String] = []
    /// Imported by the game's own executable, which outweighs every other module.
    public var fromExecutable = false
    /// Imported by an engine renderer module rather than bundled middleware
    /// (upscalers, overlays, embedded browsers) that may use another API.
    public var fromRenderer = false
    public var isEmpty: Bool { strong.isEmpty && weak.isEmpty }

    var rank: Int { fromExecutable ? 3 : fromRenderer ? 2 : strong.isEmpty ? 0 : 1 }
}

public struct GameAnalysis: Sendable {
    public struct Executable: Sendable, Equatable {
        public let apis: Set<GraphicsAPI>
        public let is32Bit: Bool
    }

    public let installDir: URL
    public let mainExecutable: URL?
    /// `mainExecutable` relative to `installDir` (both canonical), with forward slashes.
    public let mainExecutableRelative: String?
    /// Machine of the executable that renders: the main one, or the Unreal shipping
    /// executable behind a root bootstrap.
    public let mainMachine: PEFile.Machine?
    public let isDotNet: Bool
    public let engine: Engine
    public let graphics: [GraphicsAPI: Evidence]
    public let antiCheats: [AntiCheat]
    public let usesSteamworks: Bool
    public let thirdPartyLaunchers: [String]
    public let scannedModules: Int
    /// Other executables in the install (e.g. a separate DX12 build), keyed by path
    /// relative to the install dir, lower-cased.
    public let otherExecutables: [String: Executable]

    public var is32Bit: Bool { mainMachine == .i386 }

    /// APIs ordered by how likely the game renders with them: by where the evidence
    /// comes from (game executable, engine renderer, other import, string), then by preference.
    public var likelyAPIs: [GraphicsAPI] {
        graphics.filter { !$0.value.isEmpty }.keys.sorted { a, b in
            let ra = graphics[a]!.rank, rb = graphics[b]!.rank
            return ra != rb ? ra > rb : a > b
        }
    }
}

/// Scans an installed Windows game to decide how Vapor should run it.
public enum GameAnalyzer {
    static let maxModules = 600
    static let skipDirs: Set<String> = ["content", "paks", "movies", "media", "sound", "audio", "localization",
                                        "_commonredist", "redist", "directx", "vcredist", "__installer"]

    public static func analyze(installDir rawDir: URL, executable: String?) -> GameAnalysis {
        let fm = FileManager.default
        // Canonical paths (realpath keeps /private, unlike resolvingSymlinksInPath) so the
        // enumerator's URLs and the install dir share one prefix.
        let installDir = canonical(rawDir)
        let requested = executable.map(AppMetadata.normalizeExecutable)
        let main = requested.map { canonical(installDir.appendingPathComponent($0)) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }

        // Collect PE modules (exe/dll), skipping bulky asset folders.
        var modules: [URL] = []
        var names = Set<String>()                       // every file/dir name, lower-cased, for fingerprints
        if let e = fm.enumerator(at: installDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
            for case let url as URL in e {
                let lower = url.lastPathComponent.lowercased()
                names.insert(lower)
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if skipDirs.contains(lower) || e.level > 5 { e.skipDescendants() }
                    continue
                }
                if (lower.hasSuffix(".dll") || lower.hasSuffix(".exe")) && modules.count < maxModules { modules.append(canonical(url)) }
            }
        }
        if let main, !modules.contains(main) { modules.insert(main, at: 0) }

        let apiModules = GraphicsAPI.allCases.flatMap(\.modules)
        let engine = engine(names)
        let mainPE = main.flatMap { try? PEFile(url: $0) }
        let shipping = main.flatMap { stub -> URL? in
            guard engine == .unreal, mainPE.map({ $0.imports.isDisjoint(with: apiModules) }) ?? true else { return nil }
            return unrealGameExecutable(behind: stub, in: installDir)
        }
        let gameExe = shipping ?? main
        if let shipping, !modules.contains(shipping) { modules.insert(shipping, at: main == nil ? 0 : 1) }

        var graphics: [GraphicsAPI: Evidence] = [:]
        for api in GraphicsAPI.allCases { graphics[api] = Evidence() }
        var usesSteamworks = names.contains("steam_api.dll") || names.contains("steam_api64.dll")

        var otherExecutables: [String: GameAnalysis.Executable] = [:]
        for module in modules {
            let rel = relativePath(module, in: installDir) ?? module.lastPathComponent
            guard let pe = try? PEFile(url: module) else { continue }
            if pe.imports.contains("steam_api.dll") || pe.imports.contains("steam_api64.dll") { usesSteamworks = true }
            if module.pathExtension.lowercased() == "exe" && module != main && module != gameExe {
                // Another executable: its APIs describe an alternative launch, not the main one.
                var apis = Set(GraphicsAPI.allCases.filter { !pe.imports.isDisjoint(with: $0.modules) })
                if isRendererModule(module.lastPathComponent) || apis.isEmpty == false {
                    for name in PEFile.referencedNames(in: module, candidates: apiModules) {
                        if let api = GraphicsAPI.allCases.first(where: { $0.modules.contains(name) }) { apis.insert(api) }
                    }
                }
                otherExecutables[rel.lowercased()] = .init(apis: apis, is32Bit: pe.machine == .i386)
                continue
            }
            let renderer = isRendererModule(module.lastPathComponent)
            for api in GraphicsAPI.allCases where !pe.imports.isDisjoint(with: api.modules) {
                graphics[api]!.strong.append(rel)
                if module == gameExe { graphics[api]!.fromExecutable = true } else if renderer { graphics[api]!.fromRenderer = true }
            }
            // String references only matter for modules that look like renderers or the game's executables.
            if module == main || module == gameExe || renderer {
                for name in PEFile.referencedNames(in: module, candidates: apiModules) {
                    if let api = GraphicsAPI.allCases.first(where: { $0.modules.contains(name) }),
                       !graphics[api]!.strong.contains(rel) {
                        graphics[api]!.weak.append(rel)
                    }
                }
            }
        }
        // Engine-provided renderer DLLs are strong evidence on their own.
        for (file, api) in [("shaderapidx9.dll", GraphicsAPI.d3d9), ("d3d11rhi.dll", .d3d11), ("d3d12rhi.dll", .d3d12)]
            where names.contains(file) {
            if graphics[api]!.strong.isEmpty { graphics[api]!.strong.append(file) }
            graphics[api]!.fromRenderer = true
        }

        let gamePE = shipping.flatMap { try? PEFile(url: $0) } ?? mainPE
        return GameAnalysis(installDir: installDir,
                            mainExecutable: main,
                            mainExecutableRelative: main.flatMap { relativePath($0, in: installDir) ?? requested },
                            mainMachine: gamePE?.machine,
                            isDotNet: gamePE?.isDotNet ?? false,
                            engine: engine,
                            graphics: graphics,
                            antiCheats: antiCheats(names),
                            usesSteamworks: usesSteamworks,
                            thirdPartyLaunchers: launchers(names),
                            scannedModules: modules.count,
                            otherExecutables: otherExecutables)
    }

    /// UE launch entries usually name a small root stub that only starts
    /// `<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe`, where the renderer lives.
    /// `<Project>/Binaries/Win64/*.exe` next to an Unreal root stub, found by listing the project
    /// folders directly so the module cap cannot hide it.
    static func unrealGameExecutable(behind stub: URL, in installDir: URL) -> URL? {
        guard stub.deletingLastPathComponent().path == installDir.path else { return nil }
        let fm = FileManager.default
        func child(_ dir: URL, _ name: String) -> URL? {
            (try? fm.contentsOfDirectory(atPath: dir.path))?
                .first { $0.caseInsensitiveCompare(name) == .orderedSame }
                .map { dir.appendingPathComponent($0) }
        }
        var candidates: [URL] = []
        for project in (try? fm.contentsOfDirectory(atPath: installDir.path)) ?? [] where project.lowercased() != "engine" {
            guard let bin = child(installDir.appendingPathComponent(project), "Binaries"),
                  let win64 = child(bin, "Win64"),
                  let files = try? fm.contentsOfDirectory(atPath: win64.path) else { continue }
            for f in files.sorted() {
                let l = f.lowercased()
                if l.hasSuffix(".exe") && !l.contains("crashreport") { candidates.append(canonical(win64.appendingPathComponent(f))) }
            }
        }
        let shipping = candidates.filter { $0.lastPathComponent.lowercased().hasSuffix("-win64-shipping.exe") }
        let pool = shipping.isEmpty ? candidates : shipping
        let project = stub.deletingPathExtension().lastPathComponent.lowercased()
        return pool.first { $0.lastPathComponent.lowercased().hasPrefix(project) } ?? (pool.count == 1 ? pool[0] : nil)
    }

    static func relativePath(_ url: URL, in dir: URL) -> String? {
        let prefix = dir.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : nil
    }

    static func canonical(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p))
    }

    static func isRendererModule(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["shaderapi", "render", "rhi", "unityplayer", "engine", "gfx", "graphics", "d3d", "dx"].contains { n.contains($0) }
    }

    static func engine(_ names: Set<String>) -> Engine {
        if names.contains("unityplayer.dll") || names.contains("globalgamemanagers") { return .unity }
        if names.contains("engine2.dll") || names.contains("rendersystemdx11.dll") { return .source2 }
        if names.contains("shaderapidx9.dll") || names.contains("engine.dll") && names.contains("vphysics.dll") { return .source }
        if names.contains("engine") && (names.contains("binaries") || names.contains { $0.hasSuffix("-win64-shipping.exe") }) { return .unreal }
        return .unknown
    }

    static func antiCheats(_ names: Set<String>) -> [AntiCheat] {
        let table: [(String, Bool, [String])] = [
            ("Easy Anti-Cheat", false, ["easyanticheat", "easyanticheat_x64.dll", "easyanticheat_eos_setup.exe", "start_protected_game.exe"]),
            ("BattlEye", false, ["battleye", "beservice.exe", "beservice_x64.exe", "beclient_x64.dll"]),
            ("EA Javelin", true, ["eaanticheat.gameservicelauncher.exe", "eaanticheat.installer.exe"]),
            ("nProtect GameGuard", true, ["gameguard", "gamemon.des"]),
            ("XIGNCODE3", true, ["xigncode", "x3.xem"]),
            ("EQU8", true, ["equ8", "equ8_client.dll"]),
            ("mhyprot", true, ["mhyprot2.sys", "mhyprot3.sys"]),
            ("Anti-Cheat Expert", true, ["anticheatexpert", "ace-base.sys"]),
            ("PunkBuster", false, ["pnkbstra.exe", "pnkbstrb.exe"]),
        ]
        return table.compactMap { name, kernel, files in
            files.first(where: names.contains).map { AntiCheat(name: name, kernelLevel: kernel, evidence: $0) }
        }
    }

    static func launchers(_ names: Set<String>) -> [String] {
        var out: [String] = []
        if names.contains("uplay_r1_loader64.dll") || names.contains("uplay_r1_loader.dll") || names.contains("upc_r2_loader64.dll") { out.append("Ubisoft Connect") }
        if names.contains("eacore.dll") || names.contains("link2ea") { out.append("EA app") }
        if names.contains("playgtav.exe") || names.contains("rockstar games launcher") { out.append("Rockstar Launcher") }
        if names.contains("battle.net.exe") { out.append("Battle.net") }
        return out
    }
}
