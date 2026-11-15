import Foundation

/// A Wine build on this Mac that Windows Steam (and games) could run on.
public struct WineEngine: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, CaseIterable, Codable {
        case vapor, heroic, sikarugir, gptk, crossover, whisky, wineApp, homebrew

        public var displayName: String {
            switch self {
            case .vapor: return "Vapor"
            case .heroic: return "Heroic"
            case .sikarugir: return "Sikarugir"
            case .gptk: return "Game Porting Toolkit"
            case .crossover: return "CrossOver"
            case .whisky: return "Whisky"
            case .wineApp: return "Wine.app"
            case .homebrew: return "Homebrew"
            }
        }
    }

    public struct Capabilities: Sendable, Hashable {
        /// DXMT's unix side (lib/wine/x86_64-unix/winemetal.so) is already installed.
        public var hasWineMetal: Bool
        /// Apple's D3DMetal (lib/external/D3DMetal.framework) is installed.
        public var hasD3DMetal: Bool
        /// Can run 32-bit Windows programs.
        public var supports32Bit: Bool
        /// 32-bit support is Wine's upstream WoW64 mode (32-bit PE on the 64-bit unix side), not a
        /// separate 32-bit unix build or CrossOver's x86_32on64.
        public var wow64: Bool
        /// Renderer packs shipped inside the engine (lib/renderer/<kind>, Sikarugir builds).
        public var bundledPacks: [PackKind]
    }

    public let id: String
    public let name: String
    /// Wine root: bin/wine (or bin/wine64) and lib/wine live here.
    public let root: URL
    public let source: Source
    public let wine: URL
    public let capabilities: Capabilities
    /// `wine --version`, or the build's own version file when it was not probed.
    public var version: String?
    /// Why this engine cannot be the base engine for Windows Steam; nil when it can.
    public let unusableReason: String?

    public var usable: Bool { unusableReason == nil }
    public var wineserver: URL { root.appendingPathComponent("bin/wineserver") }

    /// Inspects `root`; nil when it holds no wine binary.
    public init?(root: URL, source: Source, name: String? = nil) {
        let bin = root.appendingPathComponent("bin")
        let fm = FileManager.default
        let wine = bin.appendingPathComponent("wine"), wine64 = bin.appendingPathComponent("wine64")
        let hasWine = fm.isExecutableFile(atPath: wine.path)
        guard hasWine || fm.isExecutableFile(atPath: wine64.path) else { return nil }
        self.root = root
        self.source = source
        self.wine = hasWine ? wine : wine64
        self.name = name ?? Self.displayName(forRoot: root)
        self.id = Self.identifier(forRoot: root)

        let lib = root.appendingPathComponent("lib/wine")
        let i386Windows = FileOps.isDirectory(lib.appendingPathComponent("i386-windows"))
        let i386Unix = FileOps.isDirectory(lib.appendingPathComponent("i386-unix"))
        let on64 = FileOps.isDirectory(lib.appendingPathComponent("x86_32on64-unix"))
        let renderer = root.appendingPathComponent("lib/renderer")
        capabilities = Capabilities(
            hasWineMetal: FileOps.exists(lib.appendingPathComponent("x86_64-unix/winemetal.so")),
            hasD3DMetal: FileOps.exists(root.appendingPathComponent("lib/external/D3DMetal.framework")),
            supports32Bit: i386Windows || i386Unix || on64,
            wow64: i386Windows && !i386Unix && !on64,
            bundledPacks: PackKind.allCases.filter { FileOps.isDirectory(renderer.appendingPathComponent($0.rawValue)) })

        version = (try? String(contentsOf: root.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if source == .crossover {
            unusableReason = "CrossOver 的 wine 依赖 CrossOver 自己的启动环境（bottle 管理和授权检查），单独调用无法运行 Windows Steam。"
        } else if !hasWine {
            unusableReason = "只有 bin/wine64（Wine 8 之前的布局），Vapor 需要 bin/wine。"
        } else if !fm.isExecutableFile(atPath: bin.appendingPathComponent("wineserver").path) {
            unusableReason = "缺少 bin/wineserver。"
        } else {
            unusableReason = nil
        }
    }

    /// Stable, filesystem-safe id derived from the resolved root: names the engine's variant folder.
    public static func identifier(forRoot root: URL) -> String {
        let path = FileOps.canonicalPath(root)
        let base = displayName(forRoot: root.resolvingSymlinksInPath())
        let safe = String(base.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        // FNV-1a: Swift's Hasher is seeded per process, the id has to survive restarts.
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return "\(safe)-\(String(format: "%08x", hash))"
    }

    /// Folder-derived name: wswine.bundle and app bundles are named after their container.
    static func displayName(forRoot root: URL) -> String {
        let c = root.standardizedFileURL.pathComponents
        // <Bundle>[.app]/Contents/Resources/wine, CrossOver.app/Contents/SharedSupport/CrossOver
        if c.count >= 4, c[c.count - 3] == "Contents" {
            let bundle = c[c.count - 4]
            return bundle.hasSuffix(".app") ? String(bundle.dropLast(4)) : bundle
        }
        if root.lastPathComponent == "wswine.bundle" { return root.deletingLastPathComponent().lastPathComponent }
        return root.lastPathComponent
    }

    /// Runs `wine --version` (it neither starts a wineserver nor touches a prefix).
    public func probeVersion(timeout: TimeInterval = 10) async -> String? {
        var env = ProcessInfo.processInfo.environment
        for k in ["DYLD_INSERT_LIBRARIES", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_LIBRARY_PATH"] { env.removeValue(forKey: k) }
        env["WINEDEBUG"] = "-all"
        guard let result = try? await ProcessRunner.run(wine, ["--version"], environment: env, timeout: timeout),
              result.status == 0, !result.timedOut else { return nil }
        return result.output.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }?.nilIfEmpty
    }
}

/// Finds Wine engines from Vapor, Heroic, Sikarugir, GPTK, Whisky, Wine.app, CrossOver and Homebrew.
public enum EngineCatalog {
    /// Where to look; tests point this at a fake tree.
    public struct SearchPaths: Sendable {
        public var home: URL
        public var applications: [URL]
        public var homebrewBins: [URL]
        public var vapor: VaporLocations

        public init(home: URL, applications: [URL], homebrewBins: [URL], vapor: VaporLocations) {
            self.home = home
            self.applications = applications
            self.homebrewBins = homebrewBins
            self.vapor = vapor
        }

        public static var standard: SearchPaths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return SearchPaths(home: home,
                               applications: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
                               homebrewBins: [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")],
                               vapor: .standard)
        }

        var appSupport: URL { home.appendingPathComponent("Library/Application Support") }
    }

    /// Every engine found, de-duplicated by resolved path (the first source listed wins, so Homebrew's
    /// symlink into GPTK shows up as GPTK). With `probeVersions`, versions come from `wine --version`.
    public static func discover(in paths: SearchPaths = .standard, probeVersions: Bool = true) async -> [WineEngine] {
        var engines = candidates(in: paths)
        guard probeVersions else { return engines }
        let versions = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, engine) in engines.enumerated() { group.addTask { (i, await engine.probeVersion()) } }
            var out: [Int: String] = [:]
            for await (i, v) in group { if let v { out[i] = v } }
            return out
        }
        for (i, v) in versions { engines[i].version = v }
        return engines
    }

    /// Discovery without running anything (versions from version files only).
    public static func candidates(in paths: SearchPaths = .standard) -> [WineEngine] {
        var found: [WineEngine] = []
        var seen: Set<String> = []
        func add(_ dir: URL, _ source: WineEngine.Source, name: String? = nil, search: Bool = true) {
            guard let root = search ? locateRoot(in: dir) : dir, let engine = WineEngine(root: root, source: source, name: name) else { return }
            guard seen.insert(FileOps.canonicalPath(engine.root)).inserted else { return }
            found.append(engine)
        }
        let support = paths.appSupport
        for dir in FileOps.children(paths.vapor.engines) where dir.lastPathComponent != VaporLocations.variantsFolder {
            add(dir, .vapor, name: dir.lastPathComponent)
        }
        for dir in FileOps.children(support.appendingPathComponent("heroic/tools/wine")) where FileOps.isDirectory(dir) {
            add(dir, .heroic, name: dir.lastPathComponent)
        }
        for dir in FileOps.children(support.appendingPathComponent("heroic/tools/game-porting-toolkit")) where FileOps.isDirectory(dir) {
            add(dir.appendingPathComponent("Contents/Resources/wine"), .gptk, name: dir.lastPathComponent, search: false)
        }
        for dir in FileOps.children(support.appendingPathComponent("Sikarugir/Engines")) where FileOps.isDirectory(dir) {
            add(dir, .sikarugir, name: dir.lastPathComponent)
        }
        for apps in paths.applications {
            add(apps.appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine"), .gptk, search: false)
        }
        add(support.appendingPathComponent("com.isaacmarovitz.Whisky/Libraries/Wine"), .whisky, name: "Whisky", search: false)
        for apps in paths.applications {
            for app in ["Wine Stable", "Wine Devel", "Wine Staging"] {
                add(apps.appendingPathComponent("\(app).app/Contents/Resources/wine"), .wineApp, search: false)
            }
            add(apps.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver"), .crossover, search: false)
        }
        for bin in paths.homebrewBins {
            for tool in ["wine", "wine64"] {
                let link = bin.appendingPathComponent(tool)
                guard FileOps.exists(link) else { continue }
                add(link.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent(), .homebrew,
                    name: "Homebrew \(tool)", search: false)
            }
        }
        return found
    }

    /// The Wine root inside an engine folder: itself, wswine.bundle, an app's Contents/Resources/wine,
    /// or any folder up to `maxDepth` levels down that has bin/wine (or bin/wine64).
    public static func locateRoot(in dir: URL, maxDepth: Int = 4) -> URL? {
        var level = [dir]
        for _ in 0...maxDepth {
            if let hit = level.first(where: hasWineBinary) { return hit }
            level = level.flatMap { FileOps.children($0).filter { FileOps.isDirectory($0) && !skippedFolders.contains($0.lastPathComponent) } }
            if level.isEmpty { return nil }
        }
        return nil
    }

    private static let skippedFolders: Set<String> = ["lib", "share", "include", "drive_c", "dosdevices", VaporLocations.variantsFolder]

    static func hasWineBinary(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: dir.appendingPathComponent("bin/wine").path)
            || fm.isExecutableFile(atPath: dir.appendingPathComponent("bin/wine64").path)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
