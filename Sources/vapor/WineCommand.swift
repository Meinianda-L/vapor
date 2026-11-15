import Foundation
import VaporKit

// vapor wine list                               engines found on this Mac
// vapor wine packs                              renderer packs (DXMT, DXVK, D3DMetal) found locally
// vapor wine remote                             downloadable engines and packs (GitHub releases)
// vapor wine download <dxmt|dxvk|engine:<asset>>
// vapor wine import <archive> [engine|dxmt|dxvk|d3dmetal]
// vapor wine variants [--build] [--force] [--engine <path>]
// vapor wine use <engine path> [--steam-prefix <path>]
// vapor wine prefix create [path] [--engine <path>]
// VAPOR_HOME=<dir> moves Vapor's Engines/Packs/Downloads/Prefixes/config.json (dry runs, tests).

func wineCommand(_ args: [String]) {
    var args = args
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i...i + 1)
        return (value as NSString).expandingTildeInPath
    }
    func flag(_ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }
    let enginePath = option("--engine")
    let steamPrefix = option("--steam-prefix")
    let build = flag("--build"), force = flag("--force")
    let locations = VaporLocations.standard

    switch args.first {
    case "list":
        blocking {
            let engines = await EngineCatalog.discover()
            let selected = currentEngineRoot().map { WineEngine.identifier(forRoot: $0) }
            for e in engines {
                let c = e.capabilities
                var caps: [String] = []
                if c.hasWineMetal { caps.append("winemetal") }
                if c.hasD3DMetal { caps.append("d3dmetal") }
                if c.supports32Bit { caps.append(c.wow64 ? "32-bit(wow64)" : "32-bit") }
                if !c.bundledPacks.isEmpty { caps.append("packs:" + c.bundledPacks.map(\.rawValue).joined(separator: "+")) }
                print("\(e.id == selected ? "*" : " ") \(pad(e.source.rawValue, 10)) \(pad(e.name, 28)) \(pad(e.version ?? "?", 34)) \(caps.joined(separator: " "))")
                print("    \(e.root.path)")
                if let why = e.unusableReason { print("    not usable: \(why)") }
            }
        }
    case "packs":
        blocking {
            let engines = await EngineCatalog.discover(probeVersions: false)
            for p in RendererPacks.discover(engines: engines) {
                print("\(pad(p.kind.rawValue, 9)) \(pad(p.version, 32)) \(pad(p.origin.displayName, 32)) \(p.files.count) files")
                print("    \(p.root.path)")
            }
        }
    case "remote":
        blocking {
            do {
                for a in try await EngineDownloads(locations: locations).remoteOptions() {
                    let kind: String
                    switch a.kind {
                    case .engine: kind = "engine"
                    case let .pack(p): kind = p.rawValue
                    }
                    let date = a.published.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withFullDate]) } ?? "?"
                    print("\(pad(kind, 8)) \(pad(a.name, 58)) \(pad(ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file), 9)) \(date) \(a.repository)@\(a.release)\(a.sha256 == nil ? "" : " sha256")")
                }
            } catch { fail(error) }
        }
    case "download":
        guard args.count > 1 else { print("usage: vapor wine download <dxmt|dxvk|engine:<asset name>>"); exit(2) }
        let what = args[1]
        blocking {
            do {
                let downloads = EngineDownloads(locations: locations)
                let assets = try await downloads.remoteOptions()
                let asset: RemoteAsset?
                switch what {
                case "dxmt": asset = assets.first { $0.kind == .pack(.dxmt) && !$0.prerelease }
                case "dxvk": asset = assets.first { $0.kind == .pack(.dxvk) && !$0.prerelease }
                default:
                    let name = what.hasPrefix("engine:") ? String(what.dropFirst(7)) : what
                    asset = assets.first { $0.kind == .engine && ($0.name == name || $0.installName == name) }
                }
                guard let asset else { throw WineSetupError.unknownAsset(what) }
                if downloads.installed(asset) == nil { print("downloading \(asset.name) (\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))) from \(asset.url.absoluteString)") }
                let item = try await downloads.download(asset, progress: progressPrinter())
                describe(item)
            } catch { fail(error) }
        }
    case "import":
        guard args.count > 1 else { print("usage: vapor wine import <archive> [engine|dxmt|dxvk|d3dmetal]"); exit(2) }
        let archive = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
        let kind: RemoteAsset.Kind? = args.count > 2 ? (args[2] == "engine" ? .engine : PackKind(rawValue: args[2]).map(RemoteAsset.Kind.pack)) : nil
        blocking {
            do { describe(try await EngineDownloads(locations: locations).install(archive: archive, kind: kind, progress: progressPrinter())) } catch { fail(error) }
        }
    case "variants":
        blocking {
            let engines = await EngineCatalog.discover()
            guard let root = enginePath.map({ URL(fileURLWithPath: $0) }) ?? currentEngineRoot() else { print("no engine selected; pass --engine <path>"); exit(1) }
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
            var found = engines.first { $0.root.resolvingSymlinksInPath().standardizedFileURL.path == canonical }
            if found == nil, let located = EngineCatalog.locateRoot(in: root), var e = WineEngine(root: located, source: .vapor) {
                e.version = await e.probeVersion()
                found = e
            }
            guard let engine = found else { print("no Wine engine at \(root.path)"); exit(1) }
            let packs = RendererPacks.discover(engines: engines)
            let builder = VariantBuilder(outputRoot: locations.variants)
            print("base     \(engine.name) \(engine.version ?? "?") — \(engine.root.path)")
            print("output   \(builder.outputRoot.appendingPathComponent(engine.id).path)")
            if build {
                let started = Date()
                let results = await builder.buildAll(from: engine, packs: packs, force: force)
                for r in VariantRenderer.allCases {
                    switch results[r] {
                    case let .built(dir, cloned)?: print("\(pad(r.rawValue, 9)) built (\(cloned ? "APFS clone" : "copied")) \(dir.path)")
                    case let .upToDate(dir)?: print("\(pad(r.rawValue, 9)) up to date \(dir.path)")
                    case let .skipped(why)?: print("\(pad(r.rawValue, 9)) skipped: \(why)")
                    case let .failed(why)?: print("\(pad(r.rawValue, 9)) failed: \(why)")
                    case nil: break
                    }
                }
                print(String(format: "took %.1f s", Date().timeIntervalSince(started)))
            } else {
                for r in VariantRenderer.allCases {
                    let pack = r.pack.flatMap { RendererPacks.preferred($0, for: engine, among: packs) }
                    let state: String
                    if r.pack != nil && pack == nil { state = "no pack" } else {
                        let dir = builder.directory(for: engine, renderer: r)
                        state = builder.isUpToDate(r, engine: engine, pack: pack) ? "up to date"
                            : EngineCatalog.locateRoot(in: dir, maxDepth: 0) == nil ? "not built" : "stale"
                    }
                    let source = pack.map { "\($0.version) (\($0.origin.displayName))" } ?? (r.pack == nil ? "base engine" : "-")
                    print("\(pad(r.rawValue, 9)) \(pad(state, 11)) \(source)")
                }
                if let heroic = EngineVariants.directory(for: .dxmt, base: engine.root, locations: locations) {
                    print("launcher would use for dxmt: \(heroic.path)")
                }
            }
        }
    case "use":
        guard args.count > 1 else { print("usage: vapor wine use <engine path> [--steam-prefix <path>]"); exit(2) }
        let dir = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
        guard let root = EngineCatalog.locateRoot(in: dir), let engine = WineEngine(root: root, source: .vapor) else {
            fail(WineSetupError.invalidEngine(dir.lastPathComponent))
        }
        guard engine.usable else { fail(WineSetupError.engineUnusable(engine.unusableReason ?? "")) }
        var config = VaporConfig.load(from: locations.config)
        config.engineRoot = engine.root.path
        if let steamPrefix { config.steamPrefix = steamPrefix }
        do { try config.save(to: locations.config) } catch { fail(error) }
        print("engine  \(config.engineRoot ?? "-")")
        print("prefix  \(config.steamPrefix ?? "(default: Heroic)")")
        print("saved   \(locations.config.path)")
    case "prefix":
        guard args.count > 1, args[1] == "create" else { print("usage: vapor wine prefix create [path] [--engine <path>]"); exit(2) }
        let prefix = args.count > 2 ? URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath) : locations.defaultSteamPrefix
        guard let engine = enginePath.map({ URL(fileURLWithPath: $0) }) ?? currentEngineRoot() else { print("no engine; pass --engine <path>"); exit(1) }
        blocking {
            do {
                let setup = PrefixSetup(engine: engine, prefix: prefix, locations: locations)
                print("engine \(engine.path)\nprefix \(setup.prefix.path)\nlog    \(setup.logURL.path)")
                let exe = try await setup.run { step in
                    switch step {
                    case .creatingPrefix: print("creating prefix (wineboot -u)…")
                    case let .downloadingSteam(received, total):
                        if received == total || total == 0 { print("SteamSetup.exe \(received) bytes") }
                    case .installingSteam: print("installing Steam (SteamSetup.exe /S)…")
                    case let .finished(url): print("done: \(url.path)")
                    }
                }
                var config = VaporConfig.load(from: locations.config)
                config.steamPrefix = setup.prefix.path
                if config.engineRoot == nil { config.engineRoot = engine.path }
                try config.save(to: locations.config)
                print("steam.exe \(exe.path); saved as the Steam prefix in \(locations.config.path)")
            } catch { fail(error) }
        }
    default:
        print("usage: vapor wine list | packs | remote | download <dxmt|dxvk|engine:<asset>> | import <archive> [kind]")
        print("                  | variants [--build] [--force] [--engine <path>] | use <engine> [--steam-prefix <path>] | prefix create [path]")
    }
}

/// The engine Windows Steam runs on: config, else Heroic's default.
private func currentEngineRoot() -> URL? {
    if let configured = VaporConfig.load().engineURL { return configured }
    let heroic = WindowsSteam.heroicEngine
    return FileManager.default.fileExists(atPath: heroic.path) ? heroic : nil
}

private func blocking(_ body: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await body()
        done.signal()
    }
    done.wait()
}

private func fail(_ error: Error) -> Never {
    print("error: \(error)")
    exit(1)
}

private func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

private func describe(_ item: InstalledItem) {
    switch item {
    case let .engine(e): print("engine \(e.name) installed at \(e.root.path)\(e.usable ? "" : " (not usable: \(e.unusableReason ?? ""))")")
    case let .pack(p): print("\(p.kind.rawValue) \(p.version) installed at \(p.root.path) (\(p.files.count) files)")
    }
}

/// Prints a line per 10 % of download progress and each later stage.
private func progressPrinter() -> @Sendable (DownloadEvent) -> Void {
    let last = LastDecile()
    return { event in
        switch event {
        case let .downloading(received, total):
            guard total > 0 else { return }
            let decile = Int(received * 10 / total)
            if last.advance(to: decile) { print("  \(decile * 10)% \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))") }
        case .verifying: print("  verifying sha256…")
        case .extracting: print("  extracting…")
        case .validating: print("  validating…")
        case let .finished(url): print("  finished: \(url.path)")
        }
    }
}

private final class LastDecile: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func advance(to v: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v > value else { return false }
        value = v
        return true
    }
}
