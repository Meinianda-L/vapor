import AppKit
import SwiftUI
import VaporKit

/// UI-facing wrapper around the headless Windows Steam client.
///
/// Process lifecycle and on-disk state come from `WindowsSteam`; library, installs and the download
/// queue go through `SteamUI` — Steam's own UI runtime — so they behave exactly like Steam's buttons.
@MainActor
final class EngineModel: ObservableObject {
    @Published private(set) var connection: WindowsSteam.Connection = .stopped
    /// A start, stop, install or launch is under way.
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    @Published private(set) var progress: [UInt32: WindowsSteam.Progress] = [:]
    @Published var alert: EngineAlert?
    @Published var lastLaunch: String?
    /// Games Vapor is launching or has launched that are still running.
    @Published private(set) var running: Set<UInt32> = []
    private var gameProcesses: [UInt32: Process] = [:]
    /// Mac Steam, as of the last poll (pgrep stays off the main thread).
    @Published private(set) var nativeSteamRunning = false

    /// Steam's UI runtime answered the last poll.
    @Published private(set) var uiOnline = false
    @Published private(set) var downloads: [SteamUI.Download] = []
    @Published private(set) var overview: SteamUI.Overview?
    @Published private(set) var installRun: SteamUI.Install?
    private var lastReported: String?
    @Published private(set) var steamApps: [UInt32: SteamUI.App] = [:]
    @Published private(set) var folders: [SteamUI.Folder] = []
    @Published private(set) var history: [SteamUI.Sample] = []
    @Published private(set) var account: SteamUI.Account?
    @Published private(set) var downloadsPaused = false
    /// Favourites, hidden games and user collections, from Steam's own library (cloud-synced).
    @Published private(set) var shelves: SteamUI.Shelves?
    /// The account chooser and a sign-in in progress; meaningful while Windows Steam waits for a login.
    @Published private(set) var loginUsers: [SteamUI.LoginUser] = []
    @Published private(set) var login: SteamUI.Login?
    /// Steam's UI runtime is reachable (logged on or not); sign-in needs this, the store and library need `uiOnline`.
    @Published private(set) var uiReachable = false
    /// Friend conversations with history or unread messages, and the notification tray's unread count.
    @Published private(set) var chats: [SteamUI.ChatSummary] = []
    @Published private(set) var unreadNotifications = 0
    /// Dock progress and "download finished" notifications; only for the real app (notifications need
    /// a bundle, and snapshot rendering must stay invisible).
    private let signals: DownloadSignals? = Bundle.main.bundleIdentifier != nil
        && !ProcessInfo.processInfo.arguments.contains("--snapshot") ? DownloadSignals() : nil
    /// Steam's own strings (Chinese), for errors and download states.
    let strings: SteamStrings

    let steam: WindowsSteam?
    let ui = SteamUI()
    private var timer: Timer?
    private var checking = false
    private var operations = 0 { didSet { busy = operations > 0 } }
    /// The client start in flight; callers arriving meanwhile wait for it instead of starting another.
    private var startup: Task<(WindowsSteam.Connection, Bool), Error>?
    private var forcedUIOnline = false
    private var sizeCache: [UInt32: Int64] = [:]
    private var appInfo: AppInfo?

    init() {
        steam = WindowsSteam.detectDefault()
        strings = steam.map { SteamStrings(steamRoot: $0.steamRoot) } ?? SteamStrings(table: [:])
        // Steam pushes download, wizard and library changes as they happen (see SteamUI.subscribe).
        ui.subscribe { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        refresh()
        // Only the process/login state and the live connection need a slow check.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let steam {
            Task {
                let info = await Task.detached(priority: .utility) { steam.appInfo() }.value
                self.appInfo = info
            }
        }
    }

    var statusText: String {
        guard steam != nil else { return "未找到 Windows Steam" }
        if stopping { return strings("Steam_Shutdown_Generic") ?? "正在关闭 Steam…" }
        switch connection {
        case .stopped: return "Windows Steam 未运行"
        case .starting: return "Windows Steam 连接中"
        case .loggedOn: return "Windows Steam 在线"
        case let .loggedOff(reason): return "Windows Steam 已登出（\(reason)）"
        case .needsLogin: return "Windows Steam 需要登录"
        }
    }

    var statusColor: Color {
        switch connection {
        case .loggedOn: return Theme.ok
        case .starting: return Theme.warn
        case .loggedOff, .needsLogin: return Theme.bad
        case .stopped: return Theme.tertiary
        }
    }

    var isOnline: Bool { if case .loggedOn = connection { return true }; return false }

    /// Reads the client's on-disk state off the main thread, then (re)connects the live channel.
    func refresh() {
        guard let steam, !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let (c, p, n) = await Task.detached(priority: .utility) { () -> (WindowsSteam.Connection, [UInt32: WindowsSteam.Progress], Bool) in
                var p: [UInt32: WindowsSteam.Progress] = [:]
                for app in steam.installedApps() { if let pr = steam.progress(app.appid) { p[app.appid] = pr } }
                return (steam.connection(), p, WindowsSteam.nativeSteamRunning)
            }.value
            if n != nativeSteamRunning { nativeSteamRunning = n }
            if c != connection { connection = c }
            if p != progress { progress = p }
            // Signed out, Steam's UI runtime still runs (it hosts the login); keep the channel for Vapor's sign-in.
            let reachable = steam.isRunning || isOnline ? (ui.isConnected ? true : await ui.connect()) : false
            if reachable != uiReachable { uiReachable = reachable }
            if needsSignIn && reachable { await prepareSignIn() }
            if isOnline {
                if reachable != uiOnline, reachable || !forcedUIOnline { uiOnline = reachable }
            } else if !forcedUIOnline {
                // `.starting` is a reconnect blip; the install run outlives it so its outcome is not re-reported.
                clearUIState(keepInstall: c == .starting)
            }
        }
    }

    /// What Steam's UI runtime reported belongs to a logged-on session. The library (`steamApps`)
    /// stays, so offline games keep their names and install entries.
    private func clearUIState(keepInstall: Bool = false) {
        if uiOnline { uiOnline = false }
        if !downloads.isEmpty { downloads = [] }
        signals?.update(downloads: [], overview: nil, paused: false) { _ in "" }
        if overview != nil { overview = nil }
        if !keepInstall, installRun != nil { installRun = nil }
        if !folders.isEmpty { folders = [] }
        if !history.isEmpty { history = [] }
        if account != nil { account = nil }
        if downloadsPaused { downloadsPaused = false }
    }

    private func apply(_ s: SteamUI.Snapshot) {
        if s.login != login { login = s.login }
        // The agent's heartbeat keeps pushing while the account is logged off; that must not revive the UI.
        guard isOnline || forcedUIOnline else { return }
        if !uiOnline { uiOnline = true }
        if s.downloads != downloads { downloads = s.downloads }
        if s.overview != overview { overview = s.overview }
        if s.folders != folders { folders = s.folders }
        signals?.update(downloads: s.downloads, overview: s.overview, paused: s.downloadsPaused) { [steamApps] in
            steamApps[$0]?.name ?? "App \($0)"
        }
        if s.history != history { history = s.history }
        if s.account != account { account = s.account }
        if s.downloadsPaused != downloadsPaused { downloadsPaused = s.downloadsPaused }
        if s.uninstallRequest != uninstallPrompt { uninstallPrompt = s.uninstallRequest }
        if let sh = s.shelves, sh != shelves { shelves = sh }
        if let c = s.chats, c != chats { chats = c }
        if let n = s.unreadNotifications, n != unreadNotifications { unreadNotifications = n }
        if let apps = s.apps {
            let map = Dictionary(apps.map { ($0.appid, $0) }, uniquingKeysWith: { a, _ in a })
            if map != steamApps { steamApps = map }
        }
        if s.install != installRun {
            let previous = installRun
            installRun = s.install
            if let run = s.install, previous?.done != true || previous?.appid != run.appid { report(run) }
        }
    }

    /// Surfaces install failures in Steam's own words. Agreements, keys etc. are shown by InstallFlowSheet.
    private func report(_ run: SteamUI.Install) {
        // The agent keeps its last run, so a reconnect re-delivers an outcome already shown. A run
        // still in progress resets this, so a retry that fails the same way is reported again.
        if !run.done && run.problem == nil { lastReported = nil; return }
        let key = "\(run.appid)/\(run.state)/\(run.error)/\(run.problem ?? "")"
        guard key != lastReported else { return }
        lastReported = key
        let name = steamApps[run.appid]?.name ?? "App \(run.appid)"
        if run.problem == "disk" {
            alert = .message("\(name) 需要 \(bytes(run.required))，磁盘只剩 \(bytes(run.available))。")
        } else if run.done && run.state == 15 {
            let reason = run.error != 0 ? strings.appUpdateError(run.error) ?? "错误 \(run.error)" : "未知原因"
            alert = .message(run.problem == "uninstall" ? "无法卸载 \(name)：\(reason)" : "无法安装 \(name)：\(reason)")
        }
    }

    /// The install waiting on the user (agreements, keys…), shown as a sheet. Only while Steam is
    /// reachable: offline, nothing could answer it.
    var pendingStep: SteamUI.Install? { uiOnline ? installRun.flatMap { $0.needsUser ? $0 : nil } : nil }

    /// Closes the install sheet; the run itself is cancelled in Steam when it is still alive.
    func dismissInstall() {
        if uiOnline { cancelInstall() }
        installRun = nil
    }

    /// An uninstall Steam itself asked to confirm (for example a steam://uninstall link).
    var uninstallRequest: [UInt32]? { uninstallPrompt }
    @Published private(set) var uninstallPrompt: [UInt32]?
    func answerUninstall(_ confirm: Bool) {
        uninstallPrompt = nil
        uiAction { confirm ? try await $0.confirmUninstall() : try await $0.declineUninstall() }
    }

    func acceptEulas() { uiAction { try await $0.acceptEulas() } }
    func continueInstall() { uiAction { try await $0.continueInstall() } }
    func cancelInstall() { uiAction { try await $0.cancelInstall() } }
    /// Starting one download also lifts a global pause; otherwise Steam queues it and immediately
    /// suspends it again ("Disabled (Suspended)").
    func queue(_ appid: UInt32) {
        let wasPaused = downloadsPaused
        uiAction { ui in
            if wasPaused { try await ui.setDownloadsEnabled(true) }
            try await ui.queue(appid)
        }
    }
    func setDownloadsPaused(_ paused: Bool) { uiAction { try await $0.setDownloadsEnabled(!paused) } }

    /// Starts headless; shows the login window only when no saved login exists.
    func start() {
        guard let steam, !busy else { return }
        operations += 1
        Task {
            defer { operations -= 1 }
            do { _ = try await online(steam) } catch { show(error) }
            refresh()
        }
    }

    /// At app launch: brings the client up when that needs no login window. Mac Steam is never quit
    /// for this; the conflict is put to the user instead.
    func startAtLaunch() {
        guard let steam else { return }
        Task {
            let (saved, up, native) = await Task.detached(priority: .utility) {
                (steam.hasSavedLogin, steam.isRunning, WindowsSteam.nativeSteamRunning)
            }.value
            guard saved, !up else { return }
            if native { alert = .nativeSteamRunning } else { start() }
        }
    }

    /// The client's state once it is up (started now, or already running); the flag says the login
    /// window was shown. Concurrent callers share one start.
    private func online(_ steam: WindowsSteam) async throws -> (WindowsSteam.Connection, Bool) {
        if let startup { return try await startup.value }
        let task = Task.detached { () throws -> (WindowsSteam.Connection, Bool) in
            let showsLogin = try Self.ensureStarted(steam)
            return (steam.waitForLogon(timeout: 120), showsLogin)
        }
        startup = task
        defer { startup = nil }
        let result = try await task.value
        if result.0 != connection { connection = result.0 }
        return result
    }

    /// Headless with a saved login; with the login window when there is none or Steam refused it
    /// (a running client is restarted for that). Blocking: call off the main actor.
    nonisolated private static func ensureStarted(_ steam: WindowsSteam) throws -> Bool {
        if WindowsSteam.nativeSteamRunning { throw WindowsSteam.StartError.nativeSteamRunning }
        if steam.isRunning {
            guard case .needsLogin = steam.connection() else { return false }
            steam.stop()
            try steam.start(silent: false)
            return true
        }
        let silent = steam.hasSavedLogin
        try steam.start(silent: silent)
        return !silent
    }

    func stop() {
        guard steam != nil, !busy else { return }
        operations += 1
        Task {
            defer { operations -= 1 }
            await shutDown()
            refresh()
        }
    }

    /// Graceful shutdown off the main actor; a game Vapor launched survives a stuck client.
    func shutDown() async {
        guard let steam else { return }
        stopping = true
        let keepGames = !running.isEmpty
        await Task.detached { steam.stop(keepGames: keepGames) }.value
        stopping = false
    }

    /// Steam is downloading right now (not paused or merely queued).
    var downloading: Bool {
        uiOnline && !downloadsPaused && downloads.contains { $0.active && !$0.paused && !$0.completed }
    }

    /// Asks Mac Steam to quit. `steam://exit` would launch it when it is not running, so only send it
    /// when it is.
    func quitNativeSteam() {
        Task {
            guard await Self.probeNativeSteam() else { return }
            NSWorkspace.shared.open(URL(string: "steam://exit")!)
        }
    }

    private static func probeNativeSteam() async -> Bool {
        await Task.detached(priority: .utility) { WindowsSteam.nativeSteamRunning }.value
    }

    private func show(_ error: Error) {
        if case .nativeSteamRunning? = error as? WindowsSteam.StartError { alert = .nativeSteamRunning } else { alert = .message("\(error)") }
    }

    /// Another client (usually Mac Steam) signed in to the same account and Steam dropped this one.
    var sessionReplaced: Bool {
        if case let .loggedOff(reason) = connection { return reason.localizedCaseInsensitiveContains("replaced") }
        return false
    }

    /// Quits Mac Steam if it is the other client, then has Windows Steam reconnect (its own
    /// SteamClient.User.Reconnect; a restart only if that does not bring it back).
    func reclaimSession() {
        guard let steam, !busy else { return }
        operations += 1
        Task {
            defer { operations -= 1 }
            if await Self.probeNativeSteam() {
                quitNativeSteam()
                var waited = 0
                while waited < 30, await Self.probeNativeSteam() {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
                if await Self.probeNativeSteam() { alert = .message("Mac 版 Steam 没有退出，Windows Steam 无法重新上线。"); return }
            }
            _ = try? await ui.evaluate("SteamClient.User.Reconnect(); return true;")
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let state = await Task.detached(priority: .utility) { steam.connection() }.value
                if case .loggedOn = state { refresh(); return }
            }
            // Reconnect did not take: restart the client (downloads resume where they left off).
            await shutDown()
            do { _ = try await online(steam) } catch { show(error) }
            refresh()
        }
    }

    // MARK: install / uninstall

    /// Approximate Windows download size from the cached depot manifests (appinfo is parsed once,
    /// off the main thread).
    func downloadSize(_ appid: UInt32) -> Int64? {
        if let cached = sizeCache[appid] { return cached > 0 ? cached : nil }
        guard let info = appInfo?[appid]?[path: "appinfo", "depots"] else { return nil }
        var total: Int64 = 0
        for (key, depot) in info.children where Int(key) != nil {
            let os = depot[path: "config", "oslist"]?.string ?? ""
            let lang = depot[path: "config", "language"]?.string ?? ""
            guard os.isEmpty || os.contains("windows"), lang.isEmpty || lang == "english" || lang == "schinese" else { continue }
            total += depot[path: "manifests", "public", "size"]?.int ?? 0
        }
        sizeCache[appid] = total
        return total > 0 ? total : nil
    }

    /// Exact download size and free space from Steam's install wizard; cancels before anything downloads.
    func probeInstall(_ appid: UInt32) async -> SteamUI.Install? {
        guard uiOnline else { return nil }
        return try? await ui.probeInstall(appid)
    }

    /// Installs through Steam's own install path, starting the client first if needed.
    func install(_ appid: UInt32) {
        guard let steam, !stopping else { return }
        operations += 1
        Task {
            defer { operations -= 1 }
            do {
                if !uiOnline {
                    let (state, showsLogin) = try await online(steam)
                    guard case .loggedOn = state else { alert = .message(Self.notLoggedOn(showsLogin, "无法安装")); return }
                    try await waitForUI()
                }
                // A global pause would suspend the new download the moment the wizard finishes.
                if downloadsPaused { try await ui.setDownloadsEnabled(true) }
                try await ui.install(appid)
            } catch { show(error) }
            refresh()
        }
    }

    private static func notLoggedOn(_ showsLogin: Bool, _ consequence: String) -> String {
        showsLogin ? "请在 Steam 窗口中登录，然后再试一次。" : "Windows Steam 没有登录成功，\(consequence)。"
    }

    private func waitForUI(timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await ui.snapshot()) != nil { uiOnline = true; return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw SteamUI.Failure.unreachable
    }

    func uninstall(_ appid: UInt32) {
        uiAction { try await $0.uninstall(appid) }
    }

    // MARK: accounts

    /// Windows Steam is up but nobody is signed in: Vapor's sign-in replaces the client's login window.
    var needsSignIn: Bool {
        switch connection {
        case .needsLogin: return true
        case .loggedOff: return !sessionReplaced
        default: return false
        }
    }

    /// What the client restarts with after a switch or sign-out, so it stays headless and reachable.
    static let restartArgs = "-silent -no-cef-sandbox -devtools-port \(SteamUI.port)"

    private func prepareSignIn() async {
        _ = try? await ui.hideSteamLoginWindow()
        if let users = try? await ui.loginUsers(), users != loginUsers { loginUsers = users }
    }

    func refreshLoginUsers() {
        guard uiReachable || uiOnline else { return }
        Task { if let users = try? await ui.loginUsers(), users != loginUsers { loginUsers = users } }
    }

    func startQRLogin() { uiAction(requiresLogin: false) { _ = try await $0.startQRLogin() } }
    func startPasswordLogin(account: String, password: String, remember: Bool) {
        uiAction(requiresLogin: false) { _ = try await $0.startPasswordLogin(account: account, password: password, remember: remember) }
    }
    func submitSteamGuardCode(_ code: String, type: Int) { uiAction(requiresLogin: false) { _ = try await $0.submitSteamGuardCode(code, type: type) } }
    func cancelLogin() { uiAction(requiresLogin: false) { try await $0.cancelLogin() } }
    func switchUser(_ account: String) { uiAction { try await $0.switchUser(account, restartArgs: Self.restartArgs) } }
    func signOut() { uiAction { try await $0.signOut(restartArgs: Self.restartArgs) } }
    func addAccount() { uiAction { try await $0.addAccount(restartArgs: Self.restartArgs) } }
    func forgetUser(_ account: String) {
        uiAction(requiresLogin: false) { ui in
            try await ui.forgetUser(account)
            let users = try await ui.loginUsers()
            await MainActor.run { self.loginUsers = users }
        }
    }

    var unreadChats: Int { chats.reduce(0) { $0 + $1.unread } }
    func setPersonaState(_ state: Int) { uiAction { try await $0.setPersonaState(state) } }

    func isFavorite(_ appid: UInt32) -> Bool { shelves?.favorites.contains(appid) ?? false }
    func isHidden(_ appid: UInt32) -> Bool { shelves?.hidden.contains(appid) ?? false }
    func setFavorite(_ appid: UInt32, _ on: Bool) { uiAction { try await $0.setFavorite([appid], on) } }
    func setHidden(_ appid: UInt32, _ on: Bool) { uiAction { try await $0.setHidden([appid], on) } }
    func setInCollection(_ id: String, _ appid: UInt32, _ on: Bool) { uiAction { try await $0.setInCollection(id, [appid], on) } }
    func newCollection(_ name: String, with appid: UInt32) { uiAction { try await $0.newCollection(name, [appid]) } }

    func pause(_ appid: UInt32) { uiAction { try await $0.pause(appid) } }
    func resume(_ appid: UInt32) {
        let wasPaused = downloadsPaused
        uiAction { ui in
            if wasPaused { try await ui.setDownloadsEnabled(true) }
            try await ui.resume(appid)
        }
    }
    func removeFromQueue(_ appid: UInt32) { uiAction { try await $0.remove(appid) } }
    func moveToTop(_ appid: UInt32) { uiAction { try await $0.move(appid, to: 0) } }
    func details(_ appid: UInt32) async -> SteamUI.AppDetails? { try? await ui.details(appid) }

    /// Snapshot rendering only: use Steam's UI runtime even when the account is signed out elsewhere.
    /// Sticky: polling never takes it back.
    func forceUIOnlineForSnapshot() async {
        forcedUIOnline = true
        if await ui.connect() { uiOnline = true }
    }
    func verify(_ appid: UInt32) { uiAction { try await $0.verify(appid) } }

    /// Opens a path inside the Wine prefix (C:\… as Steam reports it) in Finder.
    func reveal(windowsPath: String) {
        guard let url = unixPath(windowsPath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func unixPath(_ windowsPath: String) -> URL? {
        guard let steam, windowsPath.count > 2, windowsPath.dropFirst().hasPrefix(":") else { return nil }
        let drive = windowsPath.prefix(1).lowercased()
        let rest = windowsPath.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        let root = drive == "c" ? steam.prefix.appendingPathComponent("drive_c") : steam.prefix.appendingPathComponent("dosdevices/\(drive):")
        return root.appendingPathComponent(rest)
    }

    func showSteamWindow() { uiAction { try await $0.showSteamWindow(true) } }

    /// Runs a Steam UI call; `requiresLogin: false` for the sign-in itself, which runs while signed out.
    func uiAction(requiresLogin: Bool = true, _ body: @escaping (SteamUI) async throws -> Void) {
        guard requiresLogin ? uiOnline : (uiOnline || uiReachable) else { alert = .message("Windows Steam 未运行。"); return }
        Task {
            do { try await body(ui) } catch { alert = .message("\(error)") }
            refresh()
        }
    }

    // MARK: launch

    /// The engine variant for a renderer, cut from the engine Windows Steam runs on (a variant joins
    /// Steam's wineserver, so it must come from the same Wine build).
    static func variantDir(for renderer: Renderer, base: URL? = WindowsSteam.detectDefault()?.engine) -> URL? {
        EngineVariants.directory(for: renderer, base: base)
    }

    /// Ensures Steam is online, then runs the game with its first ladder rung.
    func play(_ game: GameItem) {
        guard let steam, !stopping, !running.contains(game.appid), let profile = game.profile, let dir = game.installDir else { return }
        let rung = profile.ladder.first
        guard let plan = profile.plan(for: rung) else { alert = .message("找不到游戏程序。"); return }
        let exe = plan.executable
        let workingDirectory = plan.workingDirectoryURL(in: dir)
        var env = profile.settings.env
        if !profile.settings.dllOverrides.isEmpty {
            env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;" + profile.settings.dllOverridesString
        }
        if !profile.settings.useMsync { env["WINEMSYNC"] = "0" }
        let args = plan.arguments + (rung?.arguments ?? []) + profile.settings.extraArguments
        let variant = rung.flatMap { Self.variantDir(for: $0.renderer) }
        let appid = game.appid
        running.insert(appid)
        lastLaunch = game.name
        operations += 1
        Task {
            defer {
                operations -= 1
                if lastLaunch == game.name { lastLaunch = nil }
            }
            do {
                let (state, showsLogin) = try await online(steam)
                guard case .loggedOn = state else {
                    running.remove(appid)
                    alert = .message(Self.notLoggedOn(showsLogin, "未启动游戏"))
                    return
                }
                // The launch options set in Steam's Properties apply to Vapor's launch as well.
                var args = args
                if let opts = await launchOptions(appid) { args += AppMetadata.commandLineArguments(opts) }
                let finalArgs = args
                let process = try await Task.detached {
                    try steam.launch(appid: appid, installDir: dir, executable: exe, arguments: finalArgs,
                                     workingDirectory: workingDirectory, engineVariant: variant, extraEnv: env)
                }.value
                // wine runs the exe in this process: it ends with the game (or early, when a launcher hands off).
                process.terminationHandler = { [weak self] _ in
                    Task { @MainActor in self?.running.remove(appid); self?.gameProcesses[appid] = nil }
                }
                if process.isRunning { gameProcesses[appid] = process } else { running.remove(appid) }
            } catch {
                running.remove(appid)
                show(error)
            }
            refresh()
        }
    }

    /// Steam's 停止: ends the game's wine process (the Windows process lives in it).
    func stopGame(_ appid: UInt32) {
        guard let process = gameProcesses[appid], process.isRunning else { running.remove(appid); return }
        process.terminate()
        // A game that ignores SIGTERM (stuck in a dialog) is killed after a grace period, as Steam does.
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Launch options from Steam's Properties. They need Steam's UI runtime, which may still be coming
    /// up right after logon, so the lookup is bounded and a miss never holds up the launch.
    private func launchOptions(_ appid: UInt32) async -> String? {
        let ui = self.ui
        return await Self.within(seconds: 20) { [weak self] in
            guard let self, (try? await self.waitForUI(timeout: 15)) != nil else { return nil }
            return try? await ui.details(appid)?.launchOptions
        }
    }

    /// `body`'s result, or nil after `seconds`. CDP calls ignore cancellation, so a late one is
    /// abandoned rather than awaited.
    nonisolated private static func within<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(await body()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

enum EngineAlert: Identifiable {
    case nativeSteamRunning
    case message(String)
    var id: String {
        switch self {
        case .nativeSteamRunning: return "native"
        case let .message(m): return m
        }
    }
}
