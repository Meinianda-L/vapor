import Foundation

/// Which engine variant a game runs on. Both DXVK renderers share the DXVK variant.
public enum VariantRenderer: String, Sendable, CaseIterable, Codable {
    case dxmt, dxvk, d3dmetal, wined3d

    public init(_ renderer: Renderer) {
        switch renderer {
        case .d3dMetal: self = .d3dmetal
        case .dxmt: self = .dxmt
        case .dxvkMoltenVK, .dxvkKosmicKrisp: self = .dxvk
        case .wined3d: self = .wined3d
        }
    }

    /// The pack overlaid onto the base; wined3d is the base engine unchanged.
    public var pack: PackKind? {
        switch self {
        case .dxmt: return .dxmt
        case .dxvk: return .dxvk
        case .d3dmetal: return .d3dmetal
        case .wined3d: return nil
        }
    }
}

/// Records what a variant was built from; a mismatch means it is rebuilt.
public struct VariantMarker: Codable, Sendable, Equatable {
    public static let fileName = ".vapor-variant.json"
    static let format = 1

    public var format: Int
    public var renderer: String
    public var baseRoot: String
    public var baseVersion: String
    /// Size and modification time of bin/wine, so a base engine updated in place is noticed.
    public var baseStamp: String
    public var packKind: String?
    public var packVersion: String?
    public var packRoot: String?

    /// Same inputs. The version string is informational: it reads differently depending on whether
    /// it came from `wine --version` or a version file, and `baseStamp` already tracks the binary.
    public func sameInputs(as other: VariantMarker) -> Bool {
        format == other.format && renderer == other.renderer && baseRoot == other.baseRoot && baseStamp == other.baseStamp
            && packKind == other.packKind && packVersion == other.packVersion && packRoot == other.packRoot
    }
}

/// Builds per-renderer engines: an APFS clone of the base engine with a renderer pack laid over
/// it, at `<outputRoot>/<engine-id>/<renderer>`. Clones share storage with the base until written,
/// so a variant costs only the overlaid files.
public struct VariantBuilder: Sendable {
    public enum Status: Sendable, Equatable {
        case built(URL, cloned: Bool)
        case upToDate(URL)
        case skipped(String)
        case failed(String)
    }

    public let outputRoot: URL

    public init(outputRoot: URL = VaporLocations.standard.variants) {
        self.outputRoot = outputRoot
    }

    public func directory(for engine: WineEngine, renderer: VariantRenderer) -> URL {
        outputRoot.appendingPathComponent(engine.id, isDirectory: true).appendingPathComponent(renderer.rawValue, isDirectory: true)
    }

    public func marker(for engine: WineEngine, renderer: VariantRenderer, pack: RendererPack?) -> VariantMarker {
        VariantMarker(format: VariantMarker.format, renderer: renderer.rawValue, baseRoot: FileOps.canonicalPath(engine.root),
                      baseVersion: engine.version ?? "", baseStamp: Self.stamp(engine.wine),
                      packKind: pack?.kind.rawValue, packVersion: pack?.version, packRoot: pack.map { FileOps.canonicalPath($0.root) })
    }

    public func existingMarker(at dir: URL) -> VariantMarker? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(VariantMarker.fileName)) else { return nil }
        return try? JSONDecoder().decode(VariantMarker.self, from: data)
    }

    public func isUpToDate(_ renderer: VariantRenderer, engine: WineEngine, pack: RendererPack?) -> Bool {
        let dir = directory(for: engine, renderer: renderer)
        guard EngineCatalog.hasWineBinary(dir), let existing = existingMarker(at: dir) else { return false }
        return existing.sameInputs(as: marker(for: engine, renderer: renderer, pack: renderer.pack == nil ? nil : pack))
    }

    /// Builds (or confirms) one variant. `pack` must match `renderer.pack`.
    public func build(_ renderer: VariantRenderer, from engine: WineEngine, pack: RendererPack?, force: Bool = false) async throws -> Status {
        guard engine.usable else { throw WineSetupError.engineUnusable(engine.unusableReason ?? "") }
        if let kind = renderer.pack, pack?.kind != kind { throw WineSetupError.noPack(kind) }
        var engine = engine
        if engine.version == nil { engine.version = await engine.probeVersion() }
        let dir = directory(for: engine, renderer: renderer)
        let expected = marker(for: engine, renderer: renderer, pack: renderer.pack == nil ? nil : pack)
        if !force, EngineCatalog.hasWineBinary(dir), existingMarker(at: dir)?.sameInputs(as: expected) == true { return .upToDate(dir) }

        let base = engine.root.resolvingSymlinksInPath()
        let overlays = renderer.pack == nil ? [] : pack?.files ?? []
        let cloned = try await offloaded { try Self.assemble(base: base, overlays: overlays, marker: expected, at: dir) }
        return .built(dir, cloned: cloned)
    }

    /// All four variants with the preferred pack for each; a missing pack skips that variant only.
    public func buildAll(from engine: WineEngine, packs: [RendererPack], force: Bool = false) async -> [VariantRenderer: Status] {
        var out: [VariantRenderer: Status] = [:]
        for renderer in VariantRenderer.allCases {
            let pack = renderer.pack.flatMap { RendererPacks.preferred($0, for: engine, among: packs) }
            if let kind = renderer.pack, pack == nil {
                out[renderer] = .skipped(WineSetupError.noPack(kind).description)
                continue
            }
            do { out[renderer] = try await build(renderer, from: engine, pack: pack, force: force) } catch {
                out[renderer] = .failed("\(error)")
            }
        }
        return out
    }

    /// Clone into a temporary sibling, overlay, write the marker, then swap it in, so a
    /// half-built variant is never left where a game would run it.
    static func assemble(base: URL, overlays: [RendererPack.Overlay], marker: VariantMarker, at dir: URL) throws -> Bool {
        let fm = FileManager.default
        let parent = dir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = parent.appendingPathComponent(".\(dir.lastPathComponent).building-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileOps.remove(work) }

        let cloned = try FileOps.cloneOrCopy(base, to: work)
        try? FileOps.remove(work.appendingPathComponent(VariantMarker.fileName))
        for overlay in overlays {
            let dest = work.appendingPathComponent(overlay.destination)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileOps.remove(dest)
            try FileOps.cloneOrCopy(overlay.source, to: dest)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(marker).write(to: work.appendingPathComponent(VariantMarker.fileName))

        let old = parent.appendingPathComponent(".\(dir.lastPathComponent).old-\(UUID().uuidString)", isDirectory: true)
        if FileOps.exists(dir) { try fm.moveItem(at: dir, to: old) }
        do { try fm.moveItem(at: work, to: dir) } catch {
            if FileOps.exists(old) { try? fm.moveItem(at: old, to: dir) }
            throw error
        }
        try? FileOps.remove(old)
        return cloned
    }

    static func stamp(_ file: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path) else { return "" }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)@\(Int64(modified))"
    }
}

/// Where a game's engine variant is, for the launcher.
public enum EngineVariants {
    /// The hand-made variants this project started with; used when Vapor has built none.
    public static var legacyRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/RE/engines", isDirectory: true)
    }

    /// Vapor's variant of `base` (default: the configured engine, else Heroic's) for `renderer`; else,
    /// for Heroic's engine only, the legacy variant of the same name; else nil (run on the base).
    /// Variants join Steam's wineserver, so one built from another Wine build is never offered.
    public static func directory(for renderer: Renderer, base: URL? = nil, locations: VaporLocations = .standard) -> URL? {
        let variant = VariantRenderer(renderer).rawValue
        let base = base ?? VaporConfig.load(from: locations.config).engineURL ?? WindowsSteam.heroicEngine
        let built = locations.variants.appendingPathComponent(WineEngine.identifier(forRoot: base)).appendingPathComponent(variant)
        if EngineCatalog.hasWineBinary(built) { return built }
        guard FileOps.canonicalPath(base) == FileOps.canonicalPath(WindowsSteam.heroicEngine) else { return nil }
        let legacy = legacyRoot.appendingPathComponent(variant)
        return EngineCatalog.hasWineBinary(legacy) ? legacy : nil
    }
}
