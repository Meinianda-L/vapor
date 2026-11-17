import Foundation

/// The parts of Steam's launch pipeline Vapor runs itself when it starts a game (install scripts, registry), and
/// the per-game setup that lets Steam start a game on Steam's own engine with the game's renderer.
extension WindowsSteam {
    /// The Windows spelling of a Mac path: C:\… inside the prefix's drive_c, Z:\… elsewhere (Wine maps Z: to /).
    public func windowsPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let driveC = prefix.appendingPathComponent("drive_c").standardizedFileURL.path
        if path == driveC || path.hasPrefix(driveC + "/") {
            return "C:" + path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\").ifEmpty("\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Runs a Windows program in Steam's wineserver and waits for it. nil when it could not start or ran past
    /// `timeout` (it is then terminated).
    func runAndWait(_ args: [String], timeout: TimeInterval) async -> Int32? {
        guard let process = try? spawn(args) else { return nil }
        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        return await Task.detached { () -> Int32? in
            process.waitUntilExit()
            watchdog.cancel()
            return process.terminationReason == .exit ? process.terminationStatus : nil
        }.value
    }

    /// Writes registry values through `regedit /S`, so the running wineserver sees them at once.
    public func applyRegistry(_ entries: [RegFile.Entry]) async throws {
        guard !entries.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vapor-\(UUID().uuidString).reg")
        try RegFile.data(entries).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard await runAndWait(["regedit", "/S", windowsPath(for: file)], timeout: 60) == 0 else {
            throw SteamLaunchError.registry
        }
    }

    // MARK: - Install scripts

    /// The scripts Steam runs before `appid`'s first launch: the game's own installscript*.vdf and, when it uses
    /// Steamworks Common Redistributables, the _CommonRedist ones (their HasRunKey skips those already run).
    public func installScripts(for appid: UInt32, installDir: URL) -> [InstallScript] {
        var scripts: [InstallScript] = []
        let ownPath = windowsPath(for: installDir)
        for file in Self.files(in: installDir, depth: 1) where Self.isInstallScript(file) {
            if let s = InstallScript.load(file, installDir: ownPath) { scripts.append(s) }
        }
        let apps = installedApps()
        let manifest = apps.first { $0.appid == appid }.flatMap { try? TextVDF.parse(contentsOf: $0.manifest) }
        let shared = Set((manifest?[path: "AppState", "SharedDepots"]?.children ?? []).compactMap { $0.value.int.map(UInt32.init) })
        for app in apps where shared.contains(app.appid) {
            let path = windowsPath(for: app.installDir)
            for file in Self.files(in: app.installDir.appendingPathComponent("_CommonRedist"), depth: 4) where Self.isInstallScript(file) {
                if let s = InstallScript.load(file, installDir: path) { scripts.append(s) }
            }
        }
        return scripts
    }

    /// Applies the scripts' registry values and runs their pending programs, marking each done as Steam does.
    /// `progress` gets the entry being run. Returns the entries that failed (Steam then asks whether to continue).
    public func runInstallScripts(_ scripts: [InstallScript], progress: @escaping @Sendable (String) -> Void) async -> [String] {
        let registry = RegistrySnapshot(prefix: prefix)
        let wow64 = FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/syswow64").path)
        var failed: [String] = []
        for script in scripts {
            let missing = script.registry.filter { !registry.isSet($0.key, $0.name) }
            do { try await applyRegistry(missing.map(RegFile.Entry.value)) } catch { failed.append(missing.first?.key ?? "registry") }
            for run in script.pendingRuns(in: registry) where !run.requires64Bit || wow64 {
                progress(run.name)
                var ok = true
                for step in run.steps where ok {
                    let program = step.program.lowercased()
                    let command = program.hasSuffix(".cmd") || program.hasSuffix(".bat") ? ["cmd", "/c", step.program] : [step.program]
                    let code = await runAndWait(command + AppMetadata.commandLineArguments(step.arguments), timeout: 900)
                    ok = code.map(Self.installerSucceeded) ?? false
                }
                if ok, let marker = run.doneMarker { try? await applyRegistry([.value(marker)]) }
                if !ok { failed.append(run.name) }
            }
        }
        return failed
    }

    /// Success, "a newer version is installed", and the reboot-required codes Windows installers return.
    static func installerSucceeded(_ code: Int32) -> Bool { [0, 1638, 1641, 3010].contains(code) }

    static func isInstallScript(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("installscript") && name.hasSuffix(".vdf")
    }

    static func files(in dir: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        return FileOps.children(dir).flatMap { FileOps.isDirectory($0) ? files(in: $0, depth: depth - 1) : [$0] }
    }

    // MARK: - Steam launch with the game's renderer

    /// Where Vapor records what it changed for a game Steam launches.
    static func steamLaunchRecord(_ appid: UInt32, locations: VaporLocations = .standard) -> URL {
        locations.root.appendingPathComponent("SteamLaunch/\(appid).json")
    }

    /// Prepares a launch by Steam on Steam's engine: the renderer's DLLs beside each executable and a per-program
    /// "native" override for them (Wine's AppDefaults), because a Steam-started game cannot pick another engine.
    /// Undoes an earlier setup first. `variant` is the renderer's engine variant (its DLLs are the ones placed).
    public func prepareSteamLaunch(appid: UInt32, renderer: Renderer, variant: URL?, executables: [URL], is32Bit: Bool) async throws {
        guard let modules = SteamLaunchRenderer.modules(for: renderer) else { throw SteamLaunchError.unsupported(renderer) }
        let previous = Self.loadSteamLaunch(appid)
        await undoSteamLaunch(appid)
        guard !modules.isEmpty else { return }
        guard let variant else { throw SteamLaunchError.noVariant }
        let arch = is32Bit ? "lib/wine/i386-windows" : "lib/wine/x86_64-windows"
        let placed = Set(previous?.files ?? [])
        var setup = SteamLaunchSetup(executables: [], files: [], modules: [])
        // Only modules the renderer replaces; the variant's other DLLs are the base engine's own.
        let wanted = modules.filter { m in
            let src = variant.appendingPathComponent("\(arch)/\(m).dll"), base = engine.appendingPathComponent("\(arch)/\(m).dll")
            return FileOps.exists(src) && !FileManager.default.contentsEqual(atPath: src.path, andPath: base.path)
        }
        for dir in Set(executables.map { $0.deletingLastPathComponent().standardizedFileURL }) {
            for m in wanted {
                let dest = dir.appendingPathComponent("\(m).dll")
                if FileOps.exists(dest) && !placed.contains(dest.path) { throw SteamLaunchError.gameShips("\(m).dll") }
            }
        }
        do {
            for dir in Set(executables.map { $0.deletingLastPathComponent().standardizedFileURL }) {
                for m in wanted {
                    let dest = dir.appendingPathComponent("\(m).dll")
                    try FileOps.remove(dest)
                    try FileOps.cloneOrCopy(variant.appendingPathComponent("\(arch)/\(m).dll"), to: dest)
                    setup.files.append(dest.path)
                }
            }
            setup.executables = Array(Set(executables.map(\.lastPathComponent))).sorted()
            setup.modules = wanted
            try Self.saveSteamLaunch(setup, appid)
            try await applyRegistry(SteamLaunchRenderer.overrides(executables: setup.executables, modules: wanted))
        } catch {
            try? Self.saveSteamLaunch(setup, appid)
            await undoSteamLaunch(appid)
            throw error
        }
    }

    /// Removes what `prepareSteamLaunch` put in place, so Vapor's own launch gets its engine's DLLs again.
    public func undoSteamLaunch(_ appid: UInt32) async {
        guard let setup = Self.loadSteamLaunch(appid) else { return }
        for path in setup.files { try? FileOps.remove(URL(fileURLWithPath: path)) }
        try? await applyRegistry(SteamLaunchRenderer.removal(executables: setup.executables, modules: setup.modules))
        try? FileManager.default.removeItem(at: Self.steamLaunchRecord(appid))
    }

    public static func hasSteamLaunchSetup(_ appid: UInt32) -> Bool { loadSteamLaunch(appid) != nil }

    static func loadSteamLaunch(_ appid: UInt32) -> SteamLaunchSetup? {
        (try? Data(contentsOf: steamLaunchRecord(appid))).flatMap { try? JSONDecoder().decode(SteamLaunchSetup.self, from: $0) }
    }

    static func saveSteamLaunch(_ setup: SteamLaunchSetup, _ appid: UInt32) throws {
        let url = steamLaunchRecord(appid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(setup).write(to: url)
    }
}

/// What Vapor changed for a game Steam launches.
struct SteamLaunchSetup: Codable, Sendable, Equatable {
    var executables: [String]
    var files: [String]
    var modules: [String]
}

public enum SteamLaunchRenderer {
    static let dxvkModules = ["d3d8", "d3d9", "d3d10core", "d3d11", "dxgi"]

    /// The DLLs to put beside a game Steam starts on its own engine, or nil when the renderer cannot work that way.
    /// DXVK is plain PE code, so it loads from the game's folder. DXMT and D3DMetal call into a Unix library that Wine
    /// only connects for DLLs loaded from the engine itself; WineD3D is the engine's own (empty list).
    public static func modules(for renderer: Renderer) -> [String]? {
        switch renderer {
        case .wined3d: return []
        case .dxvkMoltenVK, .dxvkKosmicKrisp: return dxvkModules
        case .dxmt, .d3dMetal: return nil
        }
    }

    static func key(_ exe: String) -> String { "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides" }

    /// "native" only: the DLLs carry Wine's builtin marker, and with any builtin in the order Wine would swap them for
    /// the engine's own copy.
    public static func overrides(executables: [String], modules: [String]) -> [RegFile.Entry] {
        executables.flatMap { exe in modules.map { .value(.init(key: key(exe), name: $0, value: .string("native"))) } }
    }

    public static func removal(executables: [String], modules: [String]) -> [RegFile.Entry] {
        executables.flatMap { exe in modules.map { .deleteValue(key: key(exe), name: $0) } }
    }
}

public enum SteamLaunchError: Error, CustomStringConvertible {
    case unsupported(Renderer)
    case noVariant
    case gameShips(String)
    case registry

    public var description: String {
        switch self {
        case let .unsupported(r): return String(localized: "\(r.rawValue) 只能由 Vapor 启动：它需要自己的 Wine 引擎。")
        case .noVariant: return String(localized: "还没有这个图形后端的引擎变体。")
        case let .gameShips(dll): return String(localized: "游戏自带 \(dll)，Vapor 不覆盖它。")
        case .registry: return String(localized: "无法写入 Wine 注册表。")
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
