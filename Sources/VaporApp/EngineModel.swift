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
    /// The Steam window or question to show now (see SteamDialogs); Steam's own window for it never opens.
    @Published private(set) var steamDialog: SteamUI.Dialog?
    /// Games Steam itself is launching (steam://run, a game restarting through Steam), for LaunchStatusView.
    @Published private(set) var launches: [SteamUI.Launch] = []
    @Published private(set) var steamShutdown: SteamUI.Shutdown?
    private var steamDialogs: [SteamUI.Dialog] = []
    // Steam windows and toasts (see SteamOpened.swift)
    /// Set when Steam opened a window or page Vapor has its own page for; the integrator navigates and calls `consumeSteamOpened()`.
    @Published private(set) var steamOpened: SteamOpened?
    private var seenWindowAt: Int?
    private let toasts: SteamToasts? = Bundle.main.bundleIdentifier != nil
        && !ProcessInfo.processInfo.arguments.contains("--snapshot") ? SteamToasts() : nil
    /// Answered here but maybe not yet gone from Steam's next snapshot.
    private var answeredDialogs: Set<String> = []
    /// Dock progress and "download finished" notifications; only for the real app (notifications need
    /// a bundle, and snapshot rendering must stay invisible).
    private let signals: DownloadSignals? = Bundle.main.bundleIdentifier != nil
        && !ProcessInfo.processInfo.arguments.contains("--snapshot") ? DownloadSignals() : nil
    /// Steam's own strings (Chinese), for errors and download states.
    private(set) var strings: SteamStrings

    /// Nil until first-run setup has installed Windows Steam (see OnboardingView).
    private(set) var steam: WindowsSteam? { didSet { objectWillChange.send() } }
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
        loadAppInfo()
    }

    private func loadAppInfo() {
        guard let steam else { return }
        Task {
            let info = await Task.detached(priority: .utility) { steam.appInfo() }.value
            self.appInfo = info
        }
    }

    /// First-run setup has just installed and started Windows Steam: pick it up and connect.
    func adoptSetup() {
        guard steam == nil, let found = WindowsSteam.detectDefault() else { return }
        strings = SteamStrings(steamRoot: found.steamRoot)
        steam = found
        loadAppInfo()
        refresh()
    }

    var statusText: String {
        guard steam != nil else { return String(localized: "未找到 Windows Steam") }
        if let status = nativeStatus { return status }
        if stopping { return strings("Steam_Shutdown_Generic") ?? String(localized: "正在关闭 Steam…") }
        switch connection {
        case .stopped: return String(localized: "Windows Steam 未运行")
        case .starting: return String(localized: "Windows Steam 连接中")
        case .loggedOn: return String(localized: "Windows Steam 在线")
        case let .loggedOff(reason): return String(localized: "Windows Steam 已登出（\(reason)）")
        case .needsLogin: return String(localized: "Windows Steam 需要登录")
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
            watchNativeWindows(c)
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
        // Steam asks things signed out too ("needs to be online"), so these come before the logon guard.
        if let d = s.dialogs, d != steamDialogs {
            steamDialogs = d
            answeredDialogs.formIntersection(d.map(\.id))
            showNextDialog()
        }
        if let l = s.launches, l != launches { launches = l }
        if let w = s.windows { noteOpenedWindows(w) }
        if let t = s.toasts { toasts?.update(t, say: say, appName: { [steamApps] in steamApps[$0]?.name }) }
        if s.shutdown != steamShutdown { steamShutdown = s.shutdown }
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
            alert = .message(String(localized: "\(name) 需要 \(bytes(run.required))，磁盘只剩 \(bytes(run.available))。"))
        } else if run.done && run.state == 15 {
            let reason = run.error != 0 ? strings.appUpdateError(run.error) ?? String(localized: "错误 \(run.error)") : String(localized: "未知原因")
            alert = .message(run.problem == "uninstall" ? String(localized: "无法卸载 \(name)：\(reason)") : String(localized: "无法安装 \(name)：\(reason)"))
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

    private func showNextDialog() {
        let next = questions.first?.dialog ?? steamDialogs.first { !answeredDialogs.contains($0.id) }
        if next != steamDialog { steamDialog = next }
    }

    /// Answers `steamDialog` with one of its button ids, or `SteamUI.Dialog.dismiss` (what closing Steam's window does).
    func answerDialog(_ choice: String, remember: Bool = false) {
        guard let dialog = steamDialog else { return }
        if let i = questions.firstIndex(where: { $0.dialog.id == dialog.id }) {
            let answer = questions.remove(at: i).answer
            showNextDialog()
            answer(choice)
            return
        }
        answeredDialogs.insert(dialog.id)
        showNextDialog()
        uiAction(requiresLogin: false) { try await $0.answerDialog(dialog.id, choice, remember: remember) }
    }
    func consumeSteamOpened() { steamOpened = nil }
    /// Windows the agent recorded since the last snapshot; the first snapshot only sets the baseline (earlier ones are history).
    private func noteOpenedWindows(_ windows: [SteamUI.HiddenWindow]) {
        guard let seen = seenWindowAt else { seenWindowAt = windows.map(\.at).max() ?? 0; return }
        let fresh = windows.filter { $0.at > seen }
        guard let newest = fresh.map(\.at).max() else { return }
        seenWindowAt = newest
        if let w = fresh.last(where: { $0.kind != .other || $0.url != nil }) {
            steamOpened = SteamOpened(id: w.at, kind: w.kind, url: w.url.flatMap(URL.init(string:)))
        }
    }
    func skipShaders(_ launch: SteamUI.Launch) { uiAction { try await $0.skipShaders(launch.gameActionID) } }
    func cancelLaunch(_ launch: SteamUI.Launch) { uiAction { try await $0.cancelLaunch(launch.gameActionID) } }

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

    // MARK: - Native Win32 windows

    /// Steam's own Win32 windows (steam.exe message boxes, update progress, wineboot); they never reach the
    /// screen (Shim/steamhide.m), so status windows become `statusText` and the others `nativeDialog`.
    @Published private(set) var nativeWindows: [NativeWindow] = []
    /// Pressed here but maybe not yet reported gone by the helper.
    private var answeredNativeWindows: Set<Int> = []
    private weak var watchedSteam: WindowsSteam?

    /// The native window asking something now; SteamDialogs presents it.
    var nativeDialog: NativeWindow? { nativeWindows.first { !$0.isStatus && !answeredNativeWindows.contains($0.id) } }
    /// E.g. "正在更新 Steam… 42%" while the bootstrapper's window is up.
    var nativeStatus: String? { nativeWindows.first(where: \.isStatus)?.statusLine }

    func press(_ button: NativeWindow.Button, in window: NativeWindow) {
        guard let steam, nativeWindows.contains(where: { $0.id == window.id }) else { return }
        answeredNativeWindows.insert(window.id)
        objectWillChange.send()
        steam.windows.press(button)
    }

    /// Closed without a button: what the window's Cancel (or its close box) would do.
    func dismissNative(_ window: NativeWindow) {
        guard let steam, nativeWindows.contains(where: { $0.id == window.id }) else { return }
        answeredNativeWindows.insert(window.id)
        objectWillChange.send()
        if let cancel = window.cancelButton { steam.windows.press(cancel) } else { steam.windows.close(window) }
    }

    /// Keeps vapor-winwatch running while the client runs, including a client an earlier Vapor started.
    private func watchNativeWindows(_ connection: WindowsSteam.Connection) {
        guard let steam else { return }
        if watchedSteam !== steam {
            watchedSteam = steam
            steam.windows.observe { [weak self] list in
                Task { @MainActor in
                    guard let self else { return }
                    self.answeredNativeWindows.formIntersection(list.map(\.id))
                    if list != self.nativeWindows { self.nativeWindows = list }
                }
            }
        }
        switch connection {
        case .stopped: steam.windows.stop()
        case .needsLogin: break   // running or not; start() and stop() cover both ends
        case .starting, .loggedOn, .loggedOff: steam.windows.start()
        }
    }

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

    // MARK: engine switch

    /// Why Windows Steam cannot move to another engine right now, or nil when it can. Games share
    /// Steam's wineserver, and a restart pauses downloads.
    var engineSwitchBlocker: String? {
        if !running.isEmpty { return String(localized: "游戏运行时不能切换引擎。") }
        if downloading { return String(localized: "正在下载，下载完成或暂停后再切换。") }
        if busy || stopping { return String(localized: "Windows Steam 正忙，稍后再试。") }
        return nil
    }

    /// The engine set in 运行时 differs from the one Steam runs on: restart Steam on the new one.
    func switchToConfiguredEngine() {
        guard engineSwitchBlocker == nil, let current = steam, let next = WindowsSteam.detectDefault(),
              next.engine.standardizedFileURL.path != current.engine.standardizedFileURL.path else { return }
        operations += 1
        Task {
            defer { operations -= 1 }
            let wasUp = await Task.detached { current.isRunning }.value
            if wasUp { await shutDown() }
            steam = next
            if wasUp {
                do { _ = try await online(next) } catch { show(error) }
            }
            refresh()
        }
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
                if await Self.probeNativeSteam() { alert = .message(String(localized: "Mac 版 Steam 没有退出，Windows Steam 无法重新上线。")); return }
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
        showsLogin ? String(localized: "请在 Steam 窗口中登录，然后再试一次。") : String(localized: "Windows Steam 没有登录成功，\(consequence)。")
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
        guard requiresLogin ? uiOnline : (uiOnline || uiReachable) else { alert = .message(String(localized: "Windows Steam 未运行。")); return }
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

    /// Ensures Steam is online, then runs the game with its chosen ladder rung: by Steam itself when the user turned
    /// that on and the renderer allows it, else by Vapor on the renderer's engine with Steam's cloud sync and install
    /// scripts run around it.
    func play(_ game: GameItem) {
        guard let steam, !stopping, !running.contains(game.appid), let profile = game.profile, let dir = game.installDir else { return }
        let rung = chosenRung(game.appid, in: profile)
        guard let plan = profile.plan(for: rung) else { alert = .message(String(localized: "找不到游戏程序。")); return }
        let viaSteam = steamLaunched.contains(game.appid) && steamLaunchBlocker(game) == nil
        let exe = plan.executable
        let workingDirectory = plan.workingDirectoryURL(in: dir)
        var env = profile.settings.env
        if !profile.settings.dllOverrides.isEmpty {
            env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;" + profile.settings.dllOverridesString
        }
        if !profile.settings.useMsync { env["WINEMSYNC"] = "0" }
        let args = plan.arguments + (rung?.arguments ?? []) + profile.settings.extraArguments
        let variant = rung.flatMap { Self.variantDir(for: $0.renderer) }
        let appid = game.appid, name = game.name
        running.insert(appid)
        lastLaunch = name
        operations += 1
        Task {
            defer {
                operations -= 1
                if lastLaunch == name { lastLaunch = nil }
                launchStage[appid] = nil
            }
            do {
                let (state, showsLogin) = try await online(steam)
                guard case .loggedOn = state else {
                    running.remove(appid)
                    alert = .message(Self.notLoggedOn(showsLogin, String(localized: "未启动游戏")))
                    return
                }
                if viaSteam {
                    try await launchThroughSteam(steam, game: game, profile: profile, rung: rung, plan: plan, dir: dir)
                    return
                }
                // The launch options set in Steam's Properties apply to Vapor's launch as well.
                var args = args
                if let opts = await launchOptions(appid) { args += AppMetadata.commandLineArguments(opts) }
                // Stopped while the cloud sync or an install script ran: nothing to start.
                guard await prepareDirectLaunch(steam, appid: appid, name: name, installDir: dir), running.contains(appid) else {
                    running.remove(appid)
                    return
                }
                let finalArgs = args
                let process = try await Task.detached {
                    try steam.launch(appid: appid, installDir: dir, executable: exe, arguments: finalArgs,
                                     workingDirectory: workingDirectory, engineVariant: variant, extraEnv: env)
                }.value
                // wine runs the exe in this process: it ends with the game (or early, when a launcher hands off).
                let started = Date(), renderer = rung.map { Theme.rendererLabel($0.renderer) } ?? String(localized: "当前后端")
                process.terminationHandler = { [weak self] p in
                    let quick = Date().timeIntervalSince(started) < 15 && p.terminationStatus != 0
                    Task { @MainActor in
                        guard let self else { return }
                        self.running.remove(appid); self.gameProcesses[appid] = nil
                        // A start-up crash is almost always the renderer; say which one and where to change it.
                        if quick { self.alert = .message(String(localized: "\(name) 在 \(renderer) 下启动后很快退出了。可以在游戏详情页的“候选后端”里换一个再试。")) }
                        await self.afterGame(appid, name: name)
                    }
                }
                if process.isRunning { gameProcesses[appid] = process } else { running.remove(appid) }
            } catch {
                running.remove(appid)
                show(error)
            }
            refresh()
        }
    }

    // MARK: Steam's launch pipeline

    /// Steam's words for what a launch is doing besides running the game (cloud sync, install scripts), for the line
    /// under the play button.
    @Published private(set) var launchStage: [UInt32: String] = [:]
    /// Each game's Steam Cloud state as last read, for the detail page's 云状态 line.
    @Published private(set) var cloudStates: [UInt32: SteamUI.CloudState] = [:]
    /// Games the user lets Steam start (experimental, off by default).
    @Published private(set) var steamLaunched: Set<UInt32> = Set((UserDefaults.standard.array(forKey: "steamLaunch") as? [Int] ?? [])
        .compactMap { UInt32(exactly: $0) })
    /// Running games Steam started; stopping one goes through Steam.
    private var steamStarted: Set<UInt32> = []
    /// Vapor's own questions (cloud conflict, install script failure), shown ahead of Steam's.
    private var questions: [(dialog: SteamUI.Dialog, answer: (String) -> Void)] = []

    func setSteamLaunch(_ on: Bool, for appid: UInt32) {
        if on { steamLaunched.insert(appid) } else { steamLaunched.remove(appid) }
        UserDefaults.standard.set(steamLaunched.map(Int.init).sorted(), forKey: "steamLaunch")
    }

    /// Why Steam cannot start the game with its chosen renderer, or nil when it can.
    func steamLaunchBlocker(_ game: GameItem) -> String? {
        guard let profile = game.profile else { return String(localized: "还没有分析这个游戏。") }
        let rung = chosenRung(game.appid, in: profile)
        if SteamLaunchRenderer.modules(for: rung?.renderer ?? .wined3d) == nil {
            return String(localized: "\(Theme.rendererLabel(rung?.renderer ?? .wined3d)) 需要自己的 Wine 引擎，只能由 Vapor 启动。")
        }
        if rung?.launch != nil { return String(localized: "这个后端用另一个启动项，Steam 只会运行默认启动项。") }
        if profile.plan(for: rung)?.bypassesAntiCheat == true { return String(localized: "Steam 会运行反作弊启动器，它在 macOS 上无法工作。") }
        return nil
    }

    /// Steam's launch, with the renderer's DLLs and per-program overrides set up for Steam's engine first.
    private func launchThroughSteam(_ steam: WindowsSteam, game: GameItem, profile: GameProfile, rung: LadderRung?,
                                    plan: LaunchPlan, dir: URL) async throws {
        let renderer = rung?.renderer ?? .wined3d
        var exes = [plan.executableURL(in: dir)]
        if let entry = profile.metadata?.windowsLaunch { exes.append(LaunchPlan.resolving(entry, in: dir).executableURL(in: dir)) }
        try await steam.prepareSteamLaunch(appid: game.appid, renderer: renderer, variant: Self.variantDir(for: renderer),
                                           executables: exes, is32Bit: profile.analysis.is32Bit)
        try await ui.runGame(game.appid)
        steamStarted.insert(game.appid)
        Task { await watchSteamGame(game.appid) }
    }

    /// Keeps `running` in step with Steam's list until the game Steam started has exited.
    private func watchSteamGame(_ appid: UInt32) async {
        let ui = self.ui, start = Date()
        var seen = false
        defer { running.remove(appid); steamStarted.remove(appid) }
        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let apps = try? await ui.runningApps() else {
                if !uiOnline { return }
                continue
            }
            if apps.contains(appid) { seen = true; continue }
            if seen { return }
            // Not up yet: Steam may still be syncing or installing (that shows in `launches`); a dropped launch ends here.
            if launches.contains(where: { $0.appid == appid }) { continue }
            if Date().timeIntervalSince(start) > 30 { return }
        }
    }

    /// What Steam's launch does before CreatingProcess, for a game Vapor starts: the cloud download (with Steam's
    /// questions on a conflict or failure) and the install scripts. Returns whether to go on.
    private func prepareDirectLaunch(_ steam: WindowsSteam, appid: UInt32, name: String, installDir: URL) async -> Bool {
        if uiOnline {
            launchStage[appid] = strings("LaunchApp_Action_SynchronizingCloud") ?? String(localized: "正在同步云")
            guard await syncCloud(appid, name: name, phase: .beforeLaunch) else { return false }
        }
        let scripts = await Task.detached(priority: .userInitiated) { steam.installScripts(for: appid, installDir: installDir) }.value
        if !scripts.isEmpty {
            launchStage[appid] = strings("LaunchApp_Action_RunningInstallScript_NoParens") ?? String(localized: "正在运行安装脚本…")
            let failed = await steam.runInstallScripts(scripts) { entry in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.launchStage[appid] = self.strings("LaunchApp_Action_RunningInstallScript", entry) ?? String(localized: "正在运行安装脚本（\(entry)）")
                }
            }
            if !failed.isEmpty {
                let answer = await ask(.init(vapor: "confirm", appid: appid,
                    title: .init(key: "LaunchApp_InstallScript_Failed_Title", String(localized: "安装失败")),
                    message: [.init(key: nil, String(localized: "\(failed.joined(separator: "、")) 没有装好。继续的话，\(name) 可能无法正常运行。"))],
                    buttons: [.init("continue", .init(key: "LaunchApp_InstallScript_Failed_Continue", String(localized: "仍然继续")), role: "default"),
                              .init("cancel", .init(key: "CloudSyncFailed_AppLaunch_Cancel", String(localized: "取消")), role: "cancel")]))
                guard answer == "continue" else { return false }
            }
        }
        // A Steam launch left per-program overrides that would replace this engine's renderer.
        if WindowsSteam.hasSteamLaunchSetup(appid) { await steam.undoSteamLaunch(appid) }
        return true
    }

    /// Steam's exit step for a game Vapor started: the cloud upload, once Steam no longer counts the game as running
    /// (a launcher that handed off ends before the game does).
    private func afterGame(_ appid: UInt32, name: String) async {
        guard uiOnline else { return }
        let ui = self.ui
        while (try? await ui.runningApps())?.contains(appid) == true, gameProcesses[appid] == nil {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard gameProcesses[appid] == nil else { return }
        launchStage[appid] = strings("LaunchApp_Action_SynchronizingCloud") ?? String(localized: "正在同步云")
        _ = await syncCloud(appid, name: name, phase: .afterExit)
        if gameProcesses[appid] == nil { launchStage[appid] = nil }
    }

    /// One cloud sync with Steam's questions. Returns whether a launch may go on.
    private func syncCloud(_ appid: UInt32, name: String, phase: CloudSyncPlan.Phase) async -> Bool {
        let ui = self.ui
        for _ in 0..<2 {
            let result = await ui.syncCloud(appid, phase: phase, timeout: phase == .beforeLaunch ? 120 : 300) { state in
                Task { @MainActor [weak self] in self?.showCloud(appid, state) }
            }
            let launching = phase == .beforeLaunch
            switch result {
            case .notUsed, .synchronized:
                return true
            case .pendingElsewhere:
                guard launching else { return true }
                return await ask(.init(vapor: "cloudPending", appid: appid, title: .init(key: "CloudPendingOps_Header", String(localized: "云过期")),
                    message: [.init(key: "CloudPendingOps_Description", String(localized: "您仍然可以进行此游戏，但这样可能会在您之前的游戏进度成功上传时造成冲突。"))],
                    buttons: [.init("IgnorePendingCloudSessions", .init(key: "CloudPendingOps_Continue", String(localized: "仍然进行游戏")), role: "destructive"),
                              .init("cancel", .init(key: "CloudPendingOps_Cancel", String(localized: "取消")), role: "cancel")])) == "IgnorePendingCloudSessions"
            case .failed, .timedOut:
                guard launching else {
                    alert = .message((strings("Notification_CloudSyncFailure_Title") ?? String(localized: "云错误")) + String(localized: "：\(name) 的存档没有同步到 Steam 云。"))
                    return false
                }
                return await ask(.init(vapor: "cloudSyncFailed", appid: appid, title: .init(key: "CloudSyncFailed_AppLaunch_Header", String(localized: "无法同步")),
                    message: [.init(key: "CloudSyncFailed_AppLaunch_Warning", String(localized: "警告：Steam 未能将您的 \(name) 存档与 Steam 云同步。"), name),
                              .init(key: "CloudSyncFailed_AppLaunch_Description", String(localized: "如果您现在进行游戏，可能无法获取之前的游戏进度，且可能永远失去进度。"))],
                    buttons: [.init("IgnoreCloud", .init(key: "CloudSyncFailed_AppLaunch_Continue", String(localized: "仍然进行游戏")), role: "destructive"),
                              .init("cancel", .init(key: "CloudSyncFailed_AppLaunch_Cancel", String(localized: "取消")), role: "cancel")])) == "IgnoreCloud"
            case .conflict:
                let times = try? await ui.cloudConflictTimes(appid)
                let answer = await ask(.init(vapor: "cloudConflict", appid: appid,
                    title: .init(key: launching ? "CloudConflict_AppLaunch_Header" : "CloudConflict_Header", String(localized: "云冲突")),
                    message: [.init(key: launching ? "CloudConflict_AppLaunch_Description" : "CloudConflict_Description",
                                    String(localized: "您本地的 \(name) 存档数据和 Steam 云的存储内容有冲突。"), name)],
                    note: launching ? .init(key: "CloudConflict_AppLaunch_Footer_Note", String(localized: "注意：您必须做出选择才能启动该应用程序")) : nil,
                    buttons: [.init("KeepLocal", .init(key: "CloudConflict_KeepLocal", String(localized: "本地存档"))),
                              .init("KeepRemote", .init(key: "CloudConflict_KeepRemote", String(localized: "云存档"))),
                              .init("cancel", .init(key: "CloudSyncFailed_AppLaunch_Cancel", String(localized: "取消")), role: "cancel")],
                    localTime: times?.local ?? 0, remoteTime: times?.remote ?? 0))
                guard answer == "KeepLocal" || answer == "KeepRemote" else { return false }
                guard (try? await ui.resolveCloudConflict(appid, keepLocal: answer == "KeepLocal")) != nil else { return false }
            }
        }
        return false
    }

    private func showCloud(_ appid: UInt32, _ state: SteamUI.CloudState) {
        if cloudStates[appid] != state { cloudStates[appid] = state }
        guard launchStage[appid] != nil, state.cloudStatus.isTransferring else { return }
        launchStage[appid] = cloudLabel(state)
    }

    /// Steam's 云状态 wording for a state ("已是最新", "正在上传…（40%）").
    func cloudLabel(_ state: SteamUI.CloudState) -> String {
        let key = state.cloudStatus.stringKey
        if (key == "Uploading" || key == "Downloading") && state.percent > 0,
           let s = strings("AppDetails_CloudStatus_\(key)Percent", String(state.percent)) { return s }
        return strings("AppDetails_CloudStatus_\(key)") ?? key
    }

    /// Reads a game's cloud state for the detail page; quiet when Steam is not reachable.
    func loadCloudState(_ appid: UInt32) async {
        guard uiOnline, let state = try? await ui.cloudState(appid) else { return }
        if cloudStates[appid] != state { cloudStates[appid] = state }
    }

    /// Asks one of Vapor's own questions through SteamDialogs and waits for the answer (a button id, or the
    /// cancel/dismiss id when the sheet is closed).
    private func ask(_ dialog: SteamUI.Dialog) async -> String {
        await withCheckedContinuation { c in
            questions.append((dialog, { c.resume(returning: $0) }))
            showNextDialog()
        }
    }

    // MARK: renderer choice


    /// The renderer the user picked for a game (by renderer and executable, so it survives ladder reordering).
    @Published private(set) var rendererChoices: [UInt32: String] = UserDefaults.standard.dictionary(forKey: "rendererChoices")?
        .reduce(into: [:]) { out, kv in if let id = UInt32(kv.key), let v = kv.value as? String { out[id] = v } } ?? [:]

    private static func key(_ rung: LadderRung) -> String { rung.renderer.rawValue + "|" + (rung.executable ?? "") + "|" + rung.arguments.joined(separator: " ") }

    func chosenRung(_ appid: UInt32, in profile: GameProfile) -> LadderRung? {
        guard let k = rendererChoices[appid], let rung = profile.ladder.first(where: { Self.key($0) == k }) else { return profile.ladder.first }
        return rung
    }

    func choose(_ rung: LadderRung, for appid: UInt32) {
        rendererChoices[appid] = Self.key(rung)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: rendererChoices.map { (String($0.key), $0.value) }), forKey: "rendererChoices")
    }

    /// Steam's 停止: ends the game's wine process (the Windows process lives in it).
    func stopGame(_ appid: UInt32) {
        if steamStarted.contains(appid) { uiAction { try await $0.terminateGame(appid) }; return }
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
