import Foundation

/// Creates a Wine prefix with Windows Steam in it: `wineboot -u`, then Valve's installer run silently.
public struct PrefixSetup: Sendable {
    public enum Step: Sendable, Equatable {
        case creatingPrefix
        case downloadingSteam(received: Int64, total: Int64)
        case installingSteam
        case finished(URL)
    }

    public static let steamInstallerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public let engine: URL
    public let prefix: URL
    public let locations: VaporLocations

    public init(engine: URL, prefix: URL? = nil, locations: VaporLocations = .standard) {
        self.engine = engine
        self.prefix = prefix ?? locations.defaultSteamPrefix
        self.locations = locations
    }

    public var steamExecutable: URL { SteamInstall.wine(prefix: prefix).root.appendingPathComponent("steam.exe") }
    public var isSteamInstalled: Bool { FileManager.default.fileExists(atPath: steamExecutable.path) }
    public var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vapor/prefix-setup.log")
    }

    public var environment: [String: String] {
        var env = WindowsSteam(prefix: prefix, engine: engine).wineEnvironment
        // No Mono/Gecko install prompts while the prefix is created; Steam needs neither.
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree=d;mshtml=d"
        return env
    }

    var wine: URL { engine.appendingPathComponent("bin/wine") }
    var wineserver: URL { engine.appendingPathComponent("bin/wineserver") }

    /// Refuses engines that cannot host Steam before anything is written.
    func preflight() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: wine.path) else { throw WineSetupError.invalidEngine(engine.lastPathComponent) }
        guard fm.isExecutableFile(atPath: wineserver.path) else { throw WineSetupError.engineUnusable("缺少 bin/wineserver。") }
    }

    /// Runs every step that is still missing and returns steam.exe. A prefix that already has Steam
    /// is returned untouched.
    public func run(progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> URL {
        try preflight()
        if isSteamInstalled {
            progress(.finished(steamExecutable))
            return steamExecutable
        }
        let fm = FileManager.default
        var env = environment
        // Keeps wine's processes out of the Dock, as for the Steam client itself.
        if let shim = WindowsSteam.steamHideShim { env["DYLD_INSERT_LIBRARIES"] = shim.path }
        let log = ProcessRunner.Output.append(logURL)

        progress(.creatingPrefix)
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try await step("wineboot", wine, ["wineboot", "-u"], env, timeout: 600, log)
        // wineboot returns before the prefix's services finish writing the registry.
        try await step("wineserver -w", wineserver, ["-w"], env, timeout: 180, log)
        guard fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw WineSetupError.processFailed("wineboot", -1)
        }

        try fm.createDirectory(at: locations.downloads, withIntermediateDirectories: true)
        let installer = locations.downloads.appendingPathComponent("SteamSetup.exe")
        defer { try? FileOps.remove(installer) }
        try await EngineDownloads(locations: locations).fetch(Self.steamInstallerURL, to: installer) {
            progress(.downloadingSteam(received: $0, total: $1))
        }

        progress(.installingSteam)
        let setup = try await ProcessRunner.run(wine, [installer.path, "/S"], environment: env, timeout: 900, output: log)
        // The NSIS installer can hand off to a child and return early; give steam.exe a moment.
        let deadline = Date().addingTimeInterval(60)
        while !isSteamInstalled && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000_000) }
        // Nothing should keep running in the new prefix (the installer may start Steam itself).
        _ = try? await ProcessRunner.run(wineserver, ["-k"], environment: env, timeout: 30, output: log)
        guard isSteamInstalled else {
            if setup.timedOut { throw WineSetupError.timeout("SteamSetup.exe") }
            if setup.status != 0 { throw WineSetupError.processFailed("SteamSetup.exe", setup.status) }
            throw WineSetupError.steamNotInstalled
        }
        progress(.finished(steamExecutable))
        return steamExecutable
    }

    private func step(_ what: String, _ tool: URL, _ args: [String], _ env: [String: String],
                      timeout: TimeInterval, _ log: ProcessRunner.Output) async throws {
        let result = try await ProcessRunner.run(tool, args, environment: env, timeout: timeout, output: log)
        if result.timedOut { throw WineSetupError.timeout(what) }
        guard result.status == 0 else { throw WineSetupError.processFailed(what, result.status) }
    }
}
