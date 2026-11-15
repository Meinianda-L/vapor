import Foundation

/// Graphics translation layers that are overlaid onto a copy of a base engine.
public enum PackKind: String, Sendable, CaseIterable, Codable {
    case dxmt, dxvk, d3dmetal

    public var displayName: String {
        switch self {
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .d3dmetal: return "D3DMetal"
        }
    }
}

/// A renderer pack on disk and the files it puts into an engine.
///
/// Layouts understood (all observed in the wild):
///   * DXMT/DXVK "builtin" releases and Vapor's Packs: `<arch>/…` at the top level,
///   * Sikarugir's bundled packs (lib/renderer/<kind>): `wine/<arch>/…` and `external/…`,
///   * DXVK-macOS plain releases: `x32/`, `x64/`,
///   * a whole GPTK/Whisky Wine (`lib/wine/<arch>`, `lib/external`), of which only D3DMetal's modules are taken.
public struct RendererPack: Sendable, Hashable, Identifiable {
    public enum Origin: Sendable, Hashable {
        case vapor
        case heroic
        case gptk
        /// Shipped inside an engine (lib/renderer/<kind>, or a Wine that carries D3DMetal).
        case engine(String)

        public var displayName: String {
            switch self {
            case .vapor: return "Vapor 下载"
            case .heroic: return "Heroic"
            case .gptk: return "Game Porting Toolkit"
            case let .engine(name): return "\(name) 内置"
            }
        }
    }

    /// One item copied into the engine; `destination` is relative to the engine root.
    public struct Overlay: Sendable, Hashable {
        public let source: URL
        public let destination: String
    }

    public let kind: PackKind
    public let version: String
    public let root: URL
    public let origin: Origin
    public let files: [Overlay]

    public var id: String { "\(kind.rawValue):\(root.path)" }

    /// Reads the pack at `root`; nil when it lacks what `kind` needs to work.
    public init?(kind: PackKind, root: URL, origin: Origin, version: String? = nil) {
        let root = root.resolvingSymlinksInPath()
        let files = Self.overlays(kind: kind, root: root)
        guard Self.isComplete(kind, Set(files.map(\.destination))) else { return nil }
        self.kind = kind
        self.root = root
        self.origin = origin
        self.files = files
        self.version = version ?? Self.readVersion(kind: kind, root: root)
    }

    /// The kind a folder's layout implies (used for archives whose kind is not known up front).
    public static func detectKind(at root: URL) -> PackKind? {
        let root = root.resolvingSymlinksInPath()
        // DXMT and D3DMetal also replace d3d11.dll, so they are checked before DXVK.
        for kind in [PackKind.dxmt, .d3dmetal, .dxvk] where isComplete(kind, Set(overlays(kind: kind, root: root).map(\.destination))) {
            return kind
        }
        return nil
    }

    static let archAliases = ["x32": "i386-windows", "x64": "x86_64-windows"]
    static let wineArches: Set<String> = ["i386-windows", "x86_64-windows", "x86_64-unix", "aarch64-windows"]
    /// D3DMetal's modules inside a full GPTK Wine (its lib/wine also holds the rest of Wine).
    static let d3dMetalModules: Set<String> = ["atidxx64", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx"]

    static func overlays(kind: PackKind, root: URL) -> [Overlay] {
        let fullWine = EngineCatalog.hasWineBinary(root)
        if fullWine && kind != .d3dmetal { return [] }
        let wineDir = [root.appendingPathComponent("lib/wine"), root.appendingPathComponent("wine")]
            .first { dir in FileOps.children(dir).contains { wineArches.contains($0.lastPathComponent) } } ?? root

        var out: [Overlay] = []
        for archDir in FileOps.children(wineDir) where FileOps.isDirectory(archDir) {
            let name = archDir.lastPathComponent
            guard let arch = wineArches.contains(name) ? name : archAliases[name] else { continue }
            for file in FileOps.children(archDir) {
                let ext = file.pathExtension.lowercased()
                guard ext == "dll" || ext == "so" else { continue }
                // Of a full Wine only D3DMetal's 64-bit modules; its i386 d3d11.dll is plain Wine's.
                if fullWine && (arch.hasPrefix("i386") || !d3dMetalModules.contains(file.deletingPathExtension().lastPathComponent)) { continue }
                out.append(Overlay(source: file.resolvingSymlinksInPath(), destination: "lib/wine/\(arch)/\(file.lastPathComponent)"))
            }
        }
        if kind == .d3dmetal {
            let external = [root.appendingPathComponent("lib/external"), root.appendingPathComponent("external")].first(where: FileOps.isDirectory)
            for item in external.map(FileOps.children) ?? [] {
                out.append(Overlay(source: item.resolvingSymlinksInPath(), destination: "lib/external/\(item.lastPathComponent)"))
            }
        }
        return out
    }

    static func isComplete(_ kind: PackKind, _ destinations: Set<String>) -> Bool {
        switch kind {
        case .dxmt:
            return destinations.isSuperset(of: ["lib/wine/x86_64-windows/d3d11.dll", "lib/wine/x86_64-windows/winemetal.dll",
                                                "lib/wine/x86_64-unix/winemetal.so"])
        case .dxvk:
            return destinations.contains("lib/wine/x86_64-windows/d3d11.dll") && !destinations.contains("lib/wine/x86_64-unix/winemetal.so")
        case .d3dmetal:
            return destinations.isSuperset(of: ["lib/external/D3DMetal.framework", "lib/wine/x86_64-unix/d3d11.so",
                                                "lib/wine/x86_64-windows/d3d11.dll"])
        }
    }

    /// A `version` file (Sikarugir), D3DMetal's bundle version, or the folder name
    /// (`dxmt-v0.80-builtin` → `v0.80`).
    static func readVersion(kind: PackKind, root: URL) -> String {
        if let text = try? String(contentsOf: root.appendingPathComponent("version"), encoding: .utf8),
           let v = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return v }
        if kind == .d3dmetal {
            for external in ["lib/external", "external"] {
                let plist = root.appendingPathComponent("\(external)/D3DMetal.framework/Resources/Info.plist")
                if let dict = NSDictionary(contentsOf: plist), let v = dict["CFBundleShortVersionString"] as? String { return v }
            }
        }
        return versionFromName(EngineCatalog.hasWineBinary(root) ? WineEngine.displayName(forRoot: root) : root.lastPathComponent)
    }

    static func versionFromName(_ name: String) -> String {
        var v = name
        if let r = v.range(of: "-v") { v = String(v[v.index(after: r.lowerBound)...]) }
        if v.hasSuffix("-builtin") { v = String(v.dropLast("-builtin".count)) }
        return v
    }
}

public enum RendererPacks {
    /// Packs from Vapor's downloads, Heroic's tools, GPTK, and the given engines (Sikarugir's
    /// lib/renderer packs, Wines that carry D3DMetal). De-duplicated by kind and resolved path.
    public static func discover(in paths: EngineCatalog.SearchPaths = .standard, engines: [WineEngine] = []) -> [RendererPack] {
        var found: [RendererPack] = []
        var seen: Set<String> = []
        func add(_ kind: PackKind, _ root: URL, _ origin: RendererPack.Origin) {
            guard FileOps.isDirectory(root), let pack = RendererPack(kind: kind, root: root, origin: origin) else { return }
            guard seen.insert("\(kind.rawValue):\(FileOps.canonicalPath(pack.root))").inserted else { return }
            found.append(pack)
        }
        for kind in PackKind.allCases {
            for dir in FileOps.children(paths.vapor.packs(kind)) { add(kind, dir, .vapor) }
        }
        let heroic = paths.appSupport.appendingPathComponent("heroic/tools")
        for dir in FileOps.children(heroic.appendingPathComponent("dxmt")) { add(.dxmt, dir, .heroic) }
        for dir in FileOps.children(heroic.appendingPathComponent("dxvk-macOS")) { add(.dxvk, dir, .heroic) }
        for dir in FileOps.children(heroic.appendingPathComponent("game-porting-toolkit")) {
            add(.d3dmetal, dir.appendingPathComponent("Contents/Resources/wine"), .heroic)
        }
        for apps in paths.applications {
            add(.d3dmetal, apps.appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine"), .gptk)
        }
        for engine in engines {
            for kind in engine.capabilities.bundledPacks {
                add(kind, engine.root.appendingPathComponent("lib/renderer/\(kind.rawValue)"), .engine(engine.name))
            }
            if engine.capabilities.hasD3DMetal {
                add(.d3dmetal, engine.root, engine.source == .gptk ? .gptk : .engine(engine.name))
            }
        }
        return found
    }

    /// The pack to build `engine`'s variant from: one shipped with the engine itself (built against
    /// it), else the newest Vapor download, else Heroic's, else anything else found.
    public static func preferred(_ kind: PackKind, for engine: WineEngine, among packs: [RendererPack]) -> RendererPack? {
        let enginePath = FileOps.canonicalPath(engine.root) + "/"
        func rank(_ p: RendererPack) -> Int {
            if FileOps.canonicalPath(p.root).hasPrefix(enginePath) { return 0 }
            switch p.origin {
            case .vapor: return 1
            case .heroic: return 2
            case .gptk: return 3
            case .engine: return 4
            }
        }
        return packs.filter { $0.kind == kind }.min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.version.compare(b.version, options: .numeric) == .orderedDescending
        }
    }
}
