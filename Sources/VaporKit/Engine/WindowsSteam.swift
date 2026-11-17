import Foundation

/// The Windows Steam client running headless inside a Wine prefix. It is Vapor's
/// backend for downloads, DRM, achievements and cloud saves; Vapor provides the UI.
///
/// Control surface (no private APIs):
///   * start/stop the client (`-silent`, `-shutdown`, then wineserver -k),
///   * read state from its own files (connection_log, loginusers.vdf, appmanifests),
///   * queue installs by writing an `appmanifest_<id>.acf` with StateFlags 1026,
///     which Steam picks up on its next start and downloads.
public final class WindowsSteam: @unchecked Sendable {
    public enum Connection: Equatable, Sendable {
        case stopped
        case starting
        case loggedOn(accountID: UInt64)
        case loggedOff(reason: String)
        case needsLogin
    }

    public let prefix: URL
    public let engine: URL               // Wine root containing bin/wine and bin/wineserver
    public var install: SteamInstall { .wine(prefix: prefix) }
    public var steamRoot: URL { install.root }
    public var logURL: URL
    /// The client's native Win32 windows (message boxes, update progress), read in the prefix; they never
    /// reach the Mac screen (see Shim/steamhide.m).
    public let windows: NativeWindows

    public init(prefix: URL, engine: URL) {
        self.prefix = prefix
        self.engine = engine
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vapor")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        self.logURL = logs.appendingPathComponent("windows-steam.log")
        self.windows = NativeWindows(wine: engine.appendingPathComponent("bin/wine"),
                                     environment: Self.environment(prefix: prefix),
                                     helper: Self.vaporLibrary(NativeWindows.helperName), log: logURL)
    }

    /// The engine and prefix chosen in Vapor's config, each falling back to Heroic's Steam prefix and
    /// Sikarugir engine (the zero-download default) when unset or missing.
    public static func detectDefault() -> WindowsSteam? {
        let config = VaporConfig.load()
        let fm = FileManager.default
        let prefix = [config.steamPrefixURL, heroicPrefix].compactMap { $0 }.first {
            fm.fileExists(atPath: SteamInstall.wine(prefix: $0).root.appendingPathComponent("steam.exe").path)
        }
        let engine = [config.engineURL, heroicEngine].compactMap { $0 }.first {
            fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/wine").path)
        }
        guard let prefix, let engine else { return nil }
        return WindowsSteam(prefix: prefix, engine: engine)
    }

    public static var heroicPrefix: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Heroic/Prefixes/Steam")
    }

    public static var heroicEngine: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/heroic/tools/wine/Wine-10.0-Sikarugir")
    }

    // MARK: - Environment

    public var wineEnvironment: [String: String] { Self.environment(prefix: prefix) }

    static func environment(prefix: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["DYLD_INSERT_LIBRARIES", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "STEAM_DYLD_INSERT_LIBRARIES"] {
            env.removeValue(forKey: k)
        }
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"
        env["MVK_CONFIG_LOG_LEVEL"] = "0"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        return env
    }

    @discardableResult
    func spawn(_ args: [String], env extra: [String: String] = [:], wine: URL? = nil, cwd: URL? = nil) throws -> Process {
        let p = Process()
        p.executableURL = wine ?? engine.appendingPathComponent("bin/wine")
        p.arguments = args
        p.environment = wineEnvironment.merging(extra) { $1 }
        if let cwd { p.currentDirectoryURL = cwd }
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()
        p.standardOutput = log
        p.standardError = log
        try p.run()
        return p
    }

    // MARK: - State

    /// Windows Steam processes belonging to this prefix (steam.exe and its webhelpers).
    public func clientProcesses() -> [Int32] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,command="])
        let steamExe = steamRoot.appendingPathComponent("steam.exe").path
        return out.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let space = s.firstIndex(of: " "), let pid = Int32(s[..<space]) else { return nil }
            let cmd = String(s[space...])
            let isOurs = cmd.contains(steamExe) || (Self.isWindowsClientCommand(cmd) && isPrefixProcess(pid))
            return isOurs ? pid : nil
        }
    }

    /// The Steam client as Wine lists it by Windows path: steam.exe, the helpers under `Steam\bin\`
    /// (steamwebhelper…) and steamerrorreporter. Games live under `Steam\steamapps\` and are not the client.
    static func isWindowsClientCommand(_ command: String) -> Bool {
        let cmd = command.lowercased()
        let root = "c:\\program files (x86)\\steam\\"
        guard let r = cmd.range(of: root) else { return false }
        let rest = cmd[r.upperBound...]
        if rest.hasPrefix("steamapps\\") { return false }
        return rest.hasPrefix("steam.exe") || rest.hasPrefix("bin\\") || rest.hasPrefix("steamerrorreporter")
    }

    /// Wine Windows-path commands do not show the prefix; check the process's WINEPREFIX instead.
    private func isPrefixProcess(_ pid: Int32) -> Bool {
        let env = Shell.run("/bin/ps", ["-E", "-p", String(pid), "-o", "command="])
        return env.contains("WINEPREFIX=\(prefix.path)") || !env.contains("WINEPREFIX=")
    }

    public var isRunning: Bool { !clientProcesses().isEmpty }

    /// Native macOS Steam logged into the same account would be kicked ("Session Replaced").
    public static var nativeSteamRunning: Bool {
        !Shell.run("/usr/bin/pgrep", ["-x", "steam_osx"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasSavedLogin: Bool {
        guard let users = try? TextVDF.parse(contentsOf: steamRoot.appendingPathComponent("config/loginusers.vdf"))["users"] else { return false }
        return users.children.contains { $0.value["RememberPassword"]?.string == "1" }
    }

    /// Latest connection state from Steam's own connection_log.
    public func connection() -> Connection { connection(running: isRunning) }

    private func connection(running: Bool) -> Connection {
        guard running else { return hasSavedLogin ? .stopped : .needsLogin }
        let log = steamRoot.appendingPathComponent("logs/connection_log.txt")
        guard let data = try? Data(contentsOf: log) else { return .starting }
        return Self.parseConnection(log: String(decoding: data, as: UTF8.self))
    }

    /// Interprets Steam's connection_log, newest line first. A dropped connection that Steam is
    /// retrying counts as `.starting` until the next completed logon.
    static func parseConnection(log text: String) -> Connection {
        var disconnected = false
        for raw in text.split(whereSeparator: \.isNewline).suffix(400).reversed() {
            let line = String(raw)
            if line.contains("[Logged On,"), line.contains("processing complete") {
                return disconnected ? .starting : .loggedOn(accountID: accountID(in: line) ?? 0)
            }
            // "[Logged Off, 0, 0]" is also the initial state before connecting, so only an
            // explicit log-off from the server counts. It also wins over the disconnect logged after it.
            if line.contains("RecvMsgClientLoggedOff") || line.contains("not auto reconnecting") {
                let reason = line.range(of: "ClientLoggedOff('").map { String(line[$0.upperBound...].prefix { $0 != "'" }) }
                    ?? line.range(of: "due to ").map { String(line[$0.upperBound...]) } ?? "logged off"
                return .loggedOff(reason: reason)
            }
            if disconnectMarkers.contains(where: line.contains) {
                disconnected = true
                continue
            }
            if line.contains("RecvMsgClientLogOnResponse") && !line.contains("'OK'") && !line.contains("processing complete") {
                // Anything else (Try Another CM, Service Unavailable, Timeout…) Steam retries on its own.
                return rejectsCredentials(line) ? .needsLogin : .starting
            }
        }
        return .starting
    }

    private static let disconnectMarkers = ["ConnectionDisconnected(", "SteamServersDisconnected_t",
                                            "FailDueToNoHearbeatResponse", "AsyncDisconnect("]

    /// Whether a logon response's EResult (the last quoted word) refuses the saved login itself.
    static func rejectsCredentials(_ line: String) -> Bool {
        let parts = line.split(separator: "'", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        let result = parts[parts.count - 2].lowercased().replacingOccurrences(of: " ", with: "")
        return ["invalidpassword", "accessdenied", "expired", "accountlogondenied", "accountlogindenied",
                "invalidloginauthcode", "twofactor"].contains { result.contains($0) }
    }

    static func accountID(in line: String) -> UInt64? {
        guard let r = line.range(of: "[U:1:") else { return nil }
        let digits = line[r.upperBound...].prefix { $0.isNumber }
        return UInt64(digits)
    }

    // MARK: - Lifecycle

    public enum StartError: Error, CustomStringConvertible {
        case nativeSteamRunning
        case timeout(Connection)
        public var description: String {
            switch self {
            case .nativeSteamRunning: return String(localized: "Mac 版 Steam 正在运行；同一账号同时在线会互相踢下线。")
            case let .timeout(c): return String(localized: "Windows Steam 没有在规定时间内登录（\(c)）。")
            }
        }
    }

    /// Starts the client. `silent` hides it entirely; pass false for the one-time login window.
    public func start(silent: Bool = true, allowNativeConflict: Bool = false) throws {
        if !allowNativeConflict && Self.nativeSteamRunning { throw StartError.nativeSteamRunning }
        if isRunning { windows.start(); return }
        updatePrefixQuietly()
        suppressCrashDialogs()
        launch = (Date(), silent)
        var args = [steamRoot.appendingPathComponent("steam.exe").path, "-no-cef-sandbox",
                    "-devtools-port", String(SteamUI.port)]
        if silent { args.insert("-silent", at: 1) }
        // steamui.dll opens CEF remote debugging (127.0.0.1 only) when this file exists; Vapor drives
        // the client through it (see SteamUI).
        FileManager.default.createFile(atPath: steamRoot.appendingPathComponent(".cef-enable-remote-debugging").path, contents: nil)
        // Fresh log so connection() reflects this session only.
        try? Data().write(to: steamRoot.appendingPathComponent("logs/connection_log.txt"))
        var env: [String: String] = [:]
        if let shim = Self.steamHideShim { env["DYLD_INSERT_LIBRARIES"] = shim.path }
        try spawn(args, env: env)
        windows.start()
    }

    /// Keeps Steam's processes out of the Dock and their windows off the screen (Vapor/Shim/steamhide.m).
    public static var steamHideShim: URL? { vaporLibrary("libvapor-steamhide.dylib") }

    /// A file Shim/build.sh builds: in the app's Resources (bundle.sh), in the package's build/lib for
    /// `swift build` products, or installed under Application Support.
    static func vaporLibrary(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent(name)]
        // .build/<triple>/<config>/VaporApp → the package root holding Package.swift.
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            if fm.fileExists(atPath: d.appendingPathComponent("Package.swift").path) {
                candidates.append(d.appendingPathComponent("build/lib/\(name)"))
                break
            }
            dir = d.deletingLastPathComponent()
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vapor/lib/\(name)"))
        return candidates.compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }
    }

    /// Lets the client's windows onto the screen again (the user asked to see Steam itself); off by default.
    /// The shim checks this file each time Steam orders a window, so it applies to windows shown from now on.
    public var showsSteamWindows: Bool {
        get { FileManager.default.fileExists(atPath: showWindowsFlag.path) }
        set {
            if newValue { FileManager.default.createFile(atPath: showWindowsFlag.path, contents: nil) }
            else { try? FileManager.default.removeItem(at: showWindowsFlag) }
        }
    }

    private var showWindowsFlag: URL { prefix.appendingPathComponent(".vapor-show-windows") }

    /// Steam's web helper recovers from a crashed process by itself, but Wine would put up its "program
    /// error" dialog for every crash first. Written once per prefix, before anything runs in it.
    func suppressCrashDialogs() {
        let reg = prefix.appendingPathComponent("user.reg")
        if let text = try? String(contentsOf: reg, encoding: .utf8),
           let section = text.range(of: "[Software\\\\Wine\\\\WineDbg]"),
           text[section.upperBound...].prefix(400).contains("\"ShowCrashDialog\"=dword:00000000") { return }
        guard let p = try? spawn(["reg", "add", "HKCU\\Software\\Wine\\WineDbg", "/v", "ShowCrashDialog",
                                  "/t", "REG_DWORD", "/d", "0", "/f"]) else { return }
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    }

    /// Wine updates a prefix in the first process after its engine changed, and that update asks to download
    /// Wine Mono and Gecko when the engine does not ship them. Run it first, alone, without those prompts; a
    /// prefix created by an engine that had them keeps them.
    func updatePrefixQuietly() {
        let inf = engine.appendingPathComponent("share/wine/wine.inf")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: inf.path))?[.modificationDate] as? Date else { return }
        let stamp = try? String(contentsOf: prefix.appendingPathComponent(".update-timestamp"), encoding: .utf8)
        guard Self.prefixNeedsUpdate(stamp: stamp, wineInf: modified) else { return }
        var overrides = ["winemenubuilder.exe=d"]
        for (dll, package) in [("mscoree", "mono"), ("mshtml", "gecko")] {
            let dir = engine.appendingPathComponent("share/wine/\(package)")
            if ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { overrides.append("\(dll)=d") }
        }
        var env = ["WINEDLLOVERRIDES": overrides.joined(separator: ";")]
        // Wine's "updating the configuration" window stays off the screen too.
        if let shim = Self.steamHideShim { env["DYLD_INSERT_LIBRARIES"] = shim.path }
        guard let p = try? spawn(["wineboot", "-u"], env: env) else { return }
        let deadline = Date().addingTimeInterval(180)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    }

    /// Wine's own test: `.update-timestamp` holds wine.inf's mtime in seconds, or "disable".
    static func prefixNeedsUpdate(stamp: String?, wineInf modified: Date) -> Bool {
        let s = stamp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s == "disable" { return false }
        return Int(s) != Int(modified.timeIntervalSince1970)
    }

    /// When and how the client was last started by this process.
    private var launch: (at: Date, silent: Bool)?

    /// Waits until logged on, logged off, the client is gone, or the timeout.
    public func waitForLogon(timeout: TimeInterval = 180) -> Connection {
        let deadline = Date().addingTimeInterval(timeout)
        var state = Connection.starting
        var goneSince: Date?
        var restarts = 0
        while Date() < deadline {
            let running = isRunning
            state = connection(running: running)
            if running {
                goneSince = nil
                switch state {
                case .loggedOn, .loggedOff, .needsLogin: return state
                case .stopped, .starting: break
                }
                // Steam itself only relaunches a crashed helper after about 90 s; restart at once instead,
                // and only drop the helper's profile if that crashes again.
                if restarts < 2, let launch, webHelperCrashedOnStart(since: launch.at) {
                    restarts += 1
                    restart(silent: launch.silent, freshWebCache: restarts == 2)
                }
            } else {
                // The client exited; the grace covers a fresh spawn that `ps` does not list yet.
                let since = goneSince ?? Date()
                if Date().timeIntervalSince(since) > 10 { return state }
                goneSince = since
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return state
    }

    /// Graceful shutdown, then kill what is left. Steam's exit-time cloud sync can take a while on a
    /// slow link. With `keepGames`, a stuck client is killed on its own so a running game survives.
    public func stop(timeout: TimeInterval = 90, keepGames: Bool = false) {
        // Steam may still put up a box while it shuts down; the helper goes once the client has.
        defer { if !isRunning { windows.stop() } }
        guard isRunning else { return }
        _ = try? spawn([steamRoot.appendingPathComponent("steam.exe").path, "-shutdown"])
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        guard isRunning else { return }
        if keepGames {
            for pid in clientProcesses() { kill(pid, SIGKILL) }
        } else {
            killPrefix()
        }
    }

    // MARK: - Web helper cache

    /// steamwebhelper (Steam's whole UI) keeps its Chromium profile here. The helper sometimes quits
    /// seconds after launch (seen right after the Mac wakes, when Windows network enumeration fails);
    /// the client then sits logged off until Steam retries the helper about 90 s later.
    public var webCacheURL: URL {
        let users = prefix.appendingPathComponent("drive_c/users")
        let mine = users.appendingPathComponent(NSUserName())
        let user = FileManager.default.fileExists(atPath: mine.path) ? mine
            : ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.lastPathComponent != "Public" } ?? mine
        return user.appendingPathComponent("AppData/Local/Steam/htmlcache")
    }

    /// The helper started after `since` and quit within seconds while the client stayed up.
    func webHelperCrashedOnStart(since: Date) -> Bool {
        guard let log = try? String(contentsOf: steamRoot.appendingPathComponent("logs/webhelper.txt"), encoding: .utf8) else { return false }
        return Self.webHelperCrashed(log: String(log.suffix(64 << 10)), since: since)
    }

    static func webHelperCrashed(log: String, since: Date, within: TimeInterval = 15) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func time(_ line: Substring) -> Date? {
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
            return f.date(from: String(line[line.index(after: line.startIndex)..<end]))
        }
        var launched: Date?
        for line in log.split(whereSeparator: \.isNewline) {
            guard let t = time(line), t >= since.addingTimeInterval(-2) else { continue }
            if line.contains("Startup - webhelper launched") { launched = t }
            else if line.contains("Quit message loop"), let l = launched, t.timeIntervalSince(l) <= within { return true }
        }
        return false
    }

    /// Starts the client again; with `freshWebCache` the helper's profile is first moved aside (the
    /// previous one is replaced). The logon lives in Steam's config, not there, so it survives.
    func restart(silent: Bool, freshWebCache: Bool) {
        stop(timeout: 30)
        if freshWebCache {
            let cache = webCacheURL, aside = cache.deletingLastPathComponent().appendingPathComponent("htmlcache.broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: cache, to: aside)
        }
        try? start(silent: silent, allowNativeConflict: true)
    }

    public func killPrefix() {
        let p = Process()
        p.executableURL = engine.appendingPathComponent("bin/wineserver")
        p.arguments = ["-k"]
        p.environment = wineEnvironment
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - Library

    public func appInfo() -> AppInfo? { try? AppInfo(contentsOf: install.appInfoURL) }

    /// Owned apps: Steam caches library art for every app in the account's library.
    public func ownedAppIDs() -> [UInt32] {
        let dir = steamRoot.appendingPathComponent("appcache/librarycache")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap(UInt32.init).sorted()
    }

    public func installedApps() -> [InstalledApp] { install.installedApps() }

    // MARK: - Install / progress / uninstall

    public struct Progress: Sendable, Equatable {
        public let appid: UInt32
        public let stateFlags: Int64
        public let downloaded: Int64
        public let total: Int64
        public var fraction: Double { total > 0 ? Double(downloaded) / Double(total) : 0 }
        public var isInstalled: Bool { stateFlags & 4 != 0 && stateFlags & 2 == 0 }
        public var isDownloading: Bool { stateFlags & (1024 | 1_048_576) != 0 }
        public var isQueued: Bool { stateFlags & 2 != 0 }
    }

    public func manifestURL(_ appid: UInt32) -> URL {
        steamRoot.appendingPathComponent("steamapps/appmanifest_\(appid).acf")
    }

    public func progress(_ appid: UInt32) -> Progress? {
        guard let kv = try? TextVDF.parse(contentsOf: manifestURL(appid)), let s = kv["AppState"] else { return nil }
        return Progress(appid: appid, stateFlags: s["StateFlags"]?.int ?? 0,
                        downloaded: s["BytesDownloaded"]?.int ?? 0, total: s["BytesToDownload"]?.int ?? 0)
    }

    public enum InstallError: Error, CustomStringConvertible {
        case unknownApp(UInt32), alreadyInstalled(UInt32)
        public var description: String {
            switch self {
            case let .unknownApp(id): return String(localized: "找不到 App \(String(id)) 的安装信息。")
            case let .alreadyInstalled(id): return String(localized: "App \(String(id)) 已经安装或已在队列中。")
            }
        }
    }

    /// Queues an install. Steam reads new manifests at startup, so a running client is
    /// restarted (headless) to pick it up; the download then proceeds in the background.
    public func queueInstall(_ appid: UInt32, accountSteamID64: UInt64?) throws {
        guard progress(appid) == nil else { throw InstallError.alreadyInstalled(appid) }
        guard let raw = appInfo()?[appid], let meta = AppMetadata(appid: appid, info: raw), !meta.installDir.isEmpty
        else { throw InstallError.unknownApp(appid) }
        var state = KeyValues.object([])
        let fields: [(String, String)] = [
            ("appid", String(appid)), ("Universe", "1"), ("name", meta.name), ("StateFlags", "1026"),
            ("installdir", meta.installDir), ("LastUpdated", "0"), ("SizeOnDisk", "0"), ("buildid", "0"),
            ("LastOwner", accountSteamID64.map(String.init) ?? "0"), ("BytesToDownload", "0"), ("BytesDownloaded", "0"),
            ("AutoUpdateBehavior", "0"), ("AllowOtherDownloadsWhileRunning", "0"), ("ScheduledAutoUpdate", "0"),
        ]
        for (k, v) in fields { state.set(.string(v), at: [k]) }
        let doc = KeyValues.object([("AppState", state)])
        let wasRunning = isRunning
        if wasRunning { stop() }
        try TextVDF.serialize(doc).write(to: manifestURL(appid), atomically: true, encoding: .utf8)
        if wasRunning { try start(silent: true, allowNativeConflict: false) }
    }

    /// Removes an installed game (the caller confirms with the user first).
    public func uninstall(_ appid: UInt32) throws {
        guard let app = installedApps().first(where: { $0.appid == appid }) else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        try? FileManager.default.removeItem(at: app.installDir)
        try FileManager.default.removeItem(at: app.manifest)
        let downloading = steamRoot.appendingPathComponent("steamapps/downloading/\(appid)")
        try? FileManager.default.removeItem(at: downloading)
        if wasRunning { try start(silent: true) }
    }

    // MARK: - Launch

    /// Runs a game directly (Steam must be logged on for Steamworks/DRM). A per-game
    /// engine variant joins the same wineserver, so the game can use its own renderer.
    public func launch(appid: UInt32, installDir: URL, executable: String, arguments: [String] = [],
                       workingDirectory: URL? = nil, engineVariant: URL? = nil,
                       extraEnv: [String: String] = [:]) throws -> Process {
        let exe = installDir.appendingPathComponent(executable)
        try? "\(appid)\n".write(to: exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt"),
                                atomically: true, encoding: .utf8)
        var env = extraEnv
        env["SteamAppId"] = String(appid)
        env["SteamGameId"] = String(appid)
        let wine = (engineVariant ?? engine).appendingPathComponent("bin/wine")
        return try spawn([exe.path] + arguments, env: env, wine: wine, cwd: workingDirectory ?? exe.deletingLastPathComponent())
    }
}

enum Shell {
    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
