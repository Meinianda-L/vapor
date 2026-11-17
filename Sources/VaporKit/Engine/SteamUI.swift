import Foundation

/// Drives Windows Steam through its own UI runtime.
///
/// steamui's SharedJSContext holds `SteamClient.*` — the native bindings Steam's library, download and
/// install pages are built on — plus the page's stores (appStore, collectionStore, downloadsStore, …).
/// It is reachable over CEF remote debugging (127.0.0.1 only) when `.cef-enable-remote-debugging`
/// exists next to steam.exe. Vapor injects a small agent there (`window.__vapor`) and polls it, so
/// install, download and uninstall go through exactly the code paths Steam's own buttons use.
public final class SteamUI: @unchecked Sendable {
    /// Passed to steam.exe as `-devtools-port`.
    public static let port = 38917

    public enum Failure: Error, CustomStringConvertible {
        case unreachable
        case timeout
        case noTarget(String)
        case script(String)
        case badReply
        public var description: String {
            switch self {
            case .unreachable: return String(localized: "无法连接 Windows Steam 的界面进程。")
            case .timeout: return String(localized: "Windows Steam 的界面进程没有及时响应。")
            case let .noTarget(t): return String(localized: "Windows Steam 界面里没有 \(t)。")
            case let .script(m): return String(localized: "Steam 界面脚本出错：\(m)")
            case .badReply: return String(localized: "Steam 界面返回了无法识别的数据。")
            }
        }
    }

    public struct Target: Decodable, Sendable {
        public let title: String
        public let url: String
        public let webSocketDebuggerUrl: String?
    }

    let port: Int
    private let session: URLSession
    private let link = Link()
    private let subscriber = Subscriber()

    public init(port: Int = SteamUI.port) {
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
    }

    // MARK: - CDP transport

    public func targets() async throws -> [Target] {
        // Steam's own restarts (account switch, sign-out) may drop -devtools-port; it then listens on 8080.
        for p in port == 8080 ? [port] : [port, 8080] {
            if let (data, _) = try? await session.data(from: URL(string: "http://127.0.0.1:\(p)/json")!),
               let list = try? JSONDecoder().decode([Target].self, from: data) { return list }
        }
        throw Failure.unreachable
    }

    /// One CDP command. SharedJSContext goes over the persistent connection; other targets get a
    /// short-lived socket.
    public func send(_ method: String, params: [String: Any] = [:], target title: String = "SharedJSContext") async throws -> [String: Any] {
        if title == "SharedJSContext" { return try await link.connection(self).call(method, params) }
        guard let target = try await targets().first(where: { $0.title == title }),
              let ws = target.webSocketDebuggerUrl, let url = URL(string: ws) else { throw Failure.noTarget(title) }
        let c = CDPConnection(url: url, session: session)
        defer { c.close(nil) }
        return try await c.call(method, params)
    }

    /// Runs `body` as an async function in the target and returns its value as JSON data.
    public func evaluate(_ body: String, target: String = "SharedJSContext") async throws -> Data {
        let result = try await send("Runtime.evaluate", params: [
            "expression": "(async () => JSON.stringify(await (async () => { \(body) })() ?? null))()",
            "awaitPromise": true, "returnByValue": true,
        ], target: target)
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw Failure.script(exception?["description"] as? String ?? details["text"] as? String ?? "?")
        }
        guard let value = (result["result"] as? [String: Any])?["value"] as? String else { throw Failure.badReply }
        return Data(value.utf8)
    }

    /// Calls `__vapor.<expression>`. The agent is injected when the connection opens and whenever
    /// Steam's UI context is recreated; the injection here only covers a reload racing a call.
    func agent(_ expression: String) async throws -> Data {
        try await evaluate("\(Self.injection)\nreturn await window.__vapor.\(expression);")
    }

    // MARK: - Live updates

    /// Pushes a snapshot whenever Steam's download manager, install wizard or library changes (the
    /// agent listens to the same client callbacks Steam's pages do), instead of polling.
    public func subscribe(_ handler: @escaping @Sendable (Snapshot) -> Void) {
        subscriber.set(handler)
    }

    /// Opens the live connection if Steam is up; cheap when already connected.
    public func connect() async -> Bool {
        (try? await link.connection(self)) != nil
    }

    public var isConnected: Bool { link.isOpen }

    fileprivate func open() async throws -> CDPConnection {
        guard let target = try await targets().first(where: { $0.title == "SharedJSContext" }),
              let ws = target.webSocketDebuggerUrl, let url = URL(string: ws) else { throw Failure.noTarget("SharedJSContext") }
        let c = CDPConnection(url: url, session: session)
        let subscriber = self.subscriber
        // Runtime.enable replays the existing context before it replies; open() primes that one itself.
        let enabled = Flag()
        c.onEvent = { [weak self, weak c] method, params in
            switch method {
            case "Runtime.bindingCalled" where params["name"] as? String == "__vaporEmit":
                guard let payload = params["payload"] as? String else { return }
                do { subscriber.deliver(try JSONDecoder().decode(Snapshot.self, from: Data(payload.utf8))) }
                catch { NSLog("Vapor: unreadable snapshot from Steam: \(error)") }
            case "Runtime.executionContextCreated":
                // Steam's UI reloaded: the agent and its subscription are gone with the old context.
                guard enabled.value, let self, let c,
                      ((params["context"] as? [String: Any])?["auxData"] as? [String: Any])?["isDefault"] as? Bool == true else { return }
                Task { await self.reprime(c) }
            case "Inspector.targetCrashed", "Inspector.detached":
                c?.close(Failure.unreachable)
            default: break
            }
        }
        do {
            _ = try await c.call("Runtime.addBinding", ["name": "__vaporEmit"])
            _ = try await c.call("Runtime.enable", [:])
            enabled.value = true
            _ = try await c.call("Inspector.enable", [:])
            try await prime(c)
            keepAlive(c)
            return c
        } catch {
            c.close(error)
            throw error
        }
    }

    /// Injects the agent unless this version is already there, then subscribes. Both are idempotent, so
    /// several clients (the app, the CLI) share one agent; `__vaporEmit` reaches every session that bound it.
    private func prime(_ c: CDPConnection) async throws {
        let r = try await c.call("Runtime.evaluate", ["expression": "\(Self.injection)\nwindow.__vapor.subscribe(); window.__vapor.ping?.();", "returnByValue": true])
        if let details = r["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw Failure.script(exception?["description"] as? String ?? details["text"] as? String ?? "?")
        }
    }

    /// Tells the agent a client is listening; without that it leaves Steam's own windows alone (see `attended`).
    private func keepAlive(_ c: CDPConnection) {
        Task.detached {
            while !c.isClosed {
                _ = try? await c.call("Runtime.evaluate", ["expression": "window.__vapor?.ping?.()", "returnByValue": true], timeout: 10)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// A failed re-prime would leave the connection open with nothing pushing; closing it lets `connect()` start over.
    private func reprime(_ c: CDPConnection) async {
        for _ in 0..<5 {
            if c.isClosed { return }
            if (try? await prime(c)) != nil { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        c.close(Failure.unreachable)
    }

    // MARK: - API

    public struct App: Decodable, Sendable, Equatable {
        public let appid: UInt32
        public let name: String
        public let type: Int              // 1 game, 2 application, 4 tool, 8 demo …
        public let installed: Bool
        public let displayStatus: Int
        public let percent: Int
        public let sizeOnDisk: Int64
        public let minutesPlayed: Int
        public let lastPlayed: Int
    }

    /// One row of Steam's download list (CDownloadItem): `queueIndex` -1 means not queued.
    public struct Download: Decodable, Sendable, Equatable {
        public let appid: UInt32
        public let active: Bool
        public let paused: Bool
        public let completed: Bool
        public let queueIndex: Int
        public let deferredTime: Int
        public let completedTime: Int
        public let downloaded: Int64      // k_EAppUpdateProgress_Download, summed over content/workshop/shader
        public let total: Int64
        public let buildID: Int
        public let targetBuildID: Int
        public let updateResult: Int
        public let contentTypes: [Int]    // 0 content, 1 workshop, 2 shader — those with an update

        public var isQueued: Bool { queueIndex >= 0 && deferredTime == 0 }
        public var isUpdate: Bool { buildID != 0 }
    }

    /// The download manager's live state (CDownloadOverview for this machine).
    public struct Overview: Decodable, Sendable, Equatable {
        public let appid: UInt32
        public let state: String          // "None", "Downloading", "Staging", "Committing", …
        public let paused: Bool
        public let networkBytesPerSecond: Int64
        public let peakBytesPerSecond: Int64
        public let diskBytesPerSecond: Int64
        public let percent: Double
        public let secondsRemaining: Int
        public let startTime: Int
        public let isInstall: Bool
        public let isWorkshop: Bool
        public let isShader: Bool
        public let stages: [Stage]        // indexed by EAppUpdateProgress

        public struct Stage: Decodable, Sendable, Equatable {
            public let done: Int64
            public let total: Int64
        }
        public static let stageNames = ["校验已安装文件", String(localized: "分配磁盘"), String(localized: "下载"), String(localized: "整理文件"), String(localized: "校验暂存文件"), String(localized: "复制"), String(localized: "写入")]
    }

    public struct Sample: Decodable, Sendable, Equatable {
        public let time: Int
        public let network: Int64
        public let disk: Int64
    }

    /// The install wizard as Vapor drives it. Steam's own wizard UI is detached while the agent runs.
    public struct Install: Decodable, Sendable, Equatable {
        public let appid: UInt32
        public let state: Int             // EInstallMgrState
        public let required: Int64
        public let available: Int64
        public let error: Int
        public let step: String?          // "eula", "cdkey", "password", "signup": waiting on the user
        public let problem: String?       // "disk", "uninstall", "unrequested" (a wizard Vapor did not open, closed), or a Steam error
        public let done: Bool
        public let eulas: [Eula]?
        public let keys: [Key]?

        public struct Eula: Decodable, Sendable, Equatable, Identifiable {
            public let id: String
            public let url: String
            public let version: Int
            public let title: String?
            public let content: String?   // HTML from the EULA page (?json=1)
        }
        public struct Key: Decodable, Sendable, Equatable {
            public let appid: UInt32
            public let name: String
            public let key: String
        }

        public var needsUser: Bool { step != nil && !done }

        static let stateNames = ["None", "Setup", "WaitLicense", "FreeLicense", "ShowCDKey", "WaitAppInfo", "ShowPassword",
                                 "ShowConfig", "ShowEULAs", "CreateApps", "ReadFromMedia", "ShowChangeMedia",
                                 "WaitLegacyCDKeys", "ShowSignup", "Complete", "Failed", "Canceled"]
        public var stateName: String { Self.stateNames.indices.contains(state) ? Self.stateNames[state] : "\(state)" }
    }

    public struct Folder: Decodable, Sendable, Equatable {
        public let index: Int
        public let path: String
        public let free: Int64
        public let capacity: Int64
        public let isDefault: Bool
    }

    public struct Account: Decodable, Sendable, Equatable {
        public let persona: String
        public let accountName: String
        public let steamID: String
        public let wallet: String
        public let personaState: Int      // EPersonaState of the signed-in user: 0 offline, 1 online, 3 away, 7 invisible
        public let avatar: URL?
    }

    /// One friend conversation that has history or unread messages.
    public struct ChatSummary: Decodable, Sendable, Equatable {
        public let steamID: String
        public let unread: Int
        public let lastTime: Int
        public let last: String
    }

    public struct ChatMessage: Decodable, Sendable, Equatable {
        public let fromMe: Bool
        public let text: String           // Steam BBCode ([emoticon], [url], [img] …)
        public let time: Int
        public let failed: Bool
    }

    /// An entry of Steam's notification tray (gifts, items, comments, wishlist sales, friend invites …).
    public struct Notification: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let type: Int              // ESteamNotificationType
        public let time: Int
        public let read: Bool
        public let count: Int             // rolled-up entries
        public let body: String           // the notification's JSON payload, as Steam sends it
    }

    /// A Steam account remembered on this machine (the client's account chooser).
    public struct LoginUser: Decodable, Sendable, Equatable, Identifiable {
        public let accountName: String
        public let persona: String
        public let avatar: URL?
        public let remember: Bool
        public let lastLogin: Int
        public var id: String { accountName }
    }

    /// A sign-in in progress, driven through Steam's own authentication service.
    public struct Login: Decodable, Sendable, Equatable {
        public let kind: String               // "qr" or "password"
        public let status: String             // starting, waiting, signingIn, done, failed
        public let challengeURL: String?      // QR: encode this; it changes while the code is shown
        public let account: String?
        public let confirmations: [Int]       // EAuthSessionGuardType: 2 email code, 3 mobile code, 4 approve in app, 5 email link
        public let eresult: Int               // non-1 when a step failed (5 wrong password, 65 wrong code, 84 rate limited …)
        public let failure: Int               // EFailureState of the session: 2 expired, 3 network, 5 rate limited
        public let remote: Bool               // the QR code was scanned; waiting for approval on the phone

        public var needsCode: Bool { confirmations.contains(3) || confirmations.contains(2) }
        public var codeType: Int { confirmations.contains(3) ? 3 : 2 }
    }

    public func loginUsers() async throws -> [LoginUser] {
        try JSONDecoder().decode(Lossy.List<LoginUser>.self, from: try await agent("loginUsers()")).items
    }
    public func startQRLogin() async throws -> Login {
        try JSONDecoder().decode(Login.self, from: try await agent("loginQR()"))
    }
    /// The password goes straight into Steam's RSA-encrypted credentials request; Vapor keeps no copy.
    public func startPasswordLogin(account: String, password: String, remember: Bool) async throws -> Login {
        try JSONDecoder().decode(Login.self, from: try await agent("loginPassword(\(literal(account)), \(literal(password)), \(remember))"))
    }
    /// Steam Guard code from the mobile app (type 3) or the e-mail (type 2). Returns Steam's EResult.
    public func submitSteamGuardCode(_ code: String, type: Int) async throws -> Int {
        try JSONDecoder().decode(Int.self, from: try await agent("loginCode(\(literal(code)), \(type))"))
    }
    public func cancelLogin() async throws { _ = try await agent("loginCancel()") }
    @discardableResult public func hideSteamLoginWindow() async throws -> Bool {
        try JSONDecoder().decode(Bool.self, from: try await agent("hideLoginWindow()"))
    }
    /// Account switching restarts the client with `restartArgs` (keep it headless and reachable).
    public func switchUser(_ account: String, restartArgs: String) async throws {
        _ = try await agent("switchUser(\(literal(account)), \(literal(restartArgs)))")
    }
    public func signOut(restartArgs: String) async throws { _ = try await agent("signOut(\(literal(restartArgs)))") }
    public func addAccount(restartArgs: String) async throws { _ = try await agent("addAccount(\(literal(restartArgs)))") }
    public func forgetUser(_ account: String) async throws { _ = try await agent("forgetUser(\(literal(account)))") }

    /// Messages with one friend, loading Steam's chat history on first use.
    public func chat(with steamID: String) async throws -> [ChatMessage] {
        try JSONDecoder().decode(Lossy.List<ChatMessage>.self, from: try await agent("chat(\(literal(steamID)))")).items
    }
    public func sendChat(to steamID: String, _ text: String) async throws { _ = try await agent("sendChat(\(literal(steamID)), \(literal(text)))") }
    public func markChatRead(_ steamID: String) async throws { _ = try await agent("readChat(\(literal(steamID)))") }
    public func notifications() async throws -> [Notification] {
        try JSONDecoder().decode(Lossy.List<Notification>.self, from: try await agent("notifications()")).items
    }
    public func markNotificationsViewed() async throws { _ = try await agent("notificationsViewed()") }
    /// 在线 / 离开 / 隐身 / 离线 for the signed-in user (EPersonaState 1 / 3 / 7 / 0).
    public func setPersonaState(_ state: Int) async throws { _ = try await agent("setPersona(\(state))") }

    public struct Snapshot: Decodable, Sendable, Equatable {
        public let loggedIn: Bool
        public let account: Account?
        public let downloadsPaused: Bool
        public let downloads: [Download]
        public let overview: Overview?
        public let history: [Sample]
        public let install: Install?
        public let uninstallRequest: [UInt32]?   // Steam asked to confirm an uninstall; see confirmUninstall()
        public let running: [UInt32]?            // apps running in Windows Steam; nil from older agents
        public let folders: [Folder]
        public let apps: [App]?
        public let detached: [String]            // Steam UI handlers Vapor took over
        public let shelves: Shelves?             // favourites, hidden and user collections; sent with `apps`
        public let chats: [ChatSummary]?         // friend conversations with history or unread messages
        public let unreadNotifications: Int?
        public let login: Login?                 // a Vapor-driven sign-in in progress
        public let dialogs: [Dialog]?            // Steam's windows and questions, waiting for an answer, oldest first
        public let launches: [Launch]?           // games Steam is launching (steam://run, a game restarting through Steam)
        public let shutdown: Shutdown?           // Steam is shutting down or restarting
        public let windows: [HiddenWindow]?      // Steam windows that opened and were kept hidden, newest last
        public let toasts: [Toast]?              // Steam's overlay notifications (friend online, achievement …), newest last
    }

    /// A window or question Steam would have drawn itself (cloud conflict, launch option, launch error, any
    /// confirm). Its own window never shows; Vapor presents it and answers with `answerDialog(_:_:)`.
    public struct Dialog: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        /// eula, launchOption, cloudConflict, cloudSyncFailed, cloudPending, cdkey, confirm, launchError, microtxn
        /// (a purchase in a game waiting for approval: `message` is the item, `details` the price; buttons `authorize` and `cancel`),
        /// or generic (read off Steam's page).
        public let kind: String
        public let appid: UInt32
        public let title: Text?
        public let message: [Text]
        public let note: Text?
        public let buttons: [Choice]
        public let eulas: [Install.Eula]?
        public let keys: [Install.Key]?
        public let code: Int                   // launchError: EAppUpdateError
        public let details: String?
        public let localTime: Int              // cloudConflict: newest local and cloud file times
        public let remoteTime: Int
        public let remember: Text?             // launchOption: the label of "always use this", when Steam offers it

        /// Steam's English text, with the token it came from when there is one, so Vapor can use Steam's Chinese string.
        public struct Text: Decodable, Sendable, Equatable, Hashable {
            public let text: String
            public let key: String?
            public let args: [String]
        }
        public struct Choice: Decodable, Sendable, Equatable, Identifiable, Hashable {
            public let id: String
            public let label: Text
            public let role: String?           // default, cancel, destructive, disabled
        }

        public var cancelChoice: Choice? { buttons.first { $0.role == "cancel" } }
        /// The answer that closes the dialog the way Steam's window close box would.
        public static let dismiss = "dismiss"
    }

    /// One launch as Steam's game action reports it (the "正在准备启动" window Steam no longer shows).
    public struct Launch: Decodable, Sendable, Equatable, Identifiable {
        public let gameActionID: Int
        public let appid: UInt32
        public let task: String               // Starting, UpdatingAppInfo, SynchronizingCloud, DownloadingDepots, ProcessingShaderCache, CreatingProcess…
        public let details: String
        public let request: String?           // the question it waits on (see `dialogs`), or ProcessingShaderCache (skipShaders)
        public let done: Int64
        public let total: Int64
        public let secondsRemaining: Int
        public var id: Int { gameActionID }
        public var fraction: Double? { total > 0 && done <= total ? Double(done) / Double(total) : nil }
    }

    public struct Shutdown: Decodable, Sendable, Equatable {
        public let state: Int                 // EShutdownState
        public let reason: Int                // EShutdownReason
        public let appid: UInt32              // the game or download Steam waits for
        public let allowForceQuit: Bool
        public let failed: Bool
    }

    /// A Steam window that opened on its own (steam://open/settings, a game's "view friends", a notification's link)
    /// and was kept hidden, or a page Steam navigated its main window to. Vapor shows its own page for `kind`.
    public struct HiddenWindow: Decodable, Sendable, Equatable {
        public let title: Dialog.Text?
        public let time: Int
        public let kind: Kind
        /// Milliseconds since 1970 when it opened; later than any earlier window's, so a client can tell which are new.
        public let at: Int
        /// The web page for a store or other web destination.
        public let url: String?

        public enum Kind: Sendable, Equatable {
            case settings
            case friends
            case chat(steamID: String?)
            case downloads
            case library(appid: UInt32?)
            case store(appid: UInt32?)
            case other
        }
    }

    /// One of Steam's overlay notifications (a friend came online, an achievement unlocked …). Steam's own toast window
    /// never shows; the text is what it would have said, in Steam's English unless a token was found.
    public struct Toast: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let appid: UInt32
        public let lines: [Dialog.Text]       // first the heading, then the text
        public let time: Int
    }

    /// Answers a dialog with one of its `buttons` ids, or "dismiss" (what closing Steam's window would do).
    /// `remember` is the launch-option dialog's "always use this" checkbox.
    public func answerDialog(_ id: String, _ choice: String, remember: Bool = false) async throws {
        _ = try await agent("answerDialog(\(literal(id)), \(literal(choice)), \(remember))")
    }
    /// Steam's 跳过 on the Vulkan shader step of a launch.
    public func skipShaders(_ gameActionID: Int) async throws { _ = try await agent("skipShaders(\(gameActionID))") }
    public func cancelLaunch(_ gameActionID: Int) async throws { _ = try await agent("cancelLaunch(\(gameActionID))") }

    /// The library's own organisation (collectionStore), synced by Steam across devices.
    public struct Shelves: Decodable, Sendable, Equatable {
        public let favorites: [UInt32]
        public let hidden: [UInt32]
        public let collections: [Collection]

        public struct Collection: Decodable, Sendable, Equatable, Identifiable {
            public let id: String
            public let name: String
            public let apps: [UInt32]
            public let dynamic: Bool       // filter-based: apps cannot be added by hand
        }
    }

    public func setFavorite(_ appids: [UInt32], _ on: Bool) async throws { _ = try await agent("shelf('favorite', \(appids), \(on))") }
    public func setHidden(_ appids: [UInt32], _ on: Bool) async throws { _ = try await agent("shelf('hidden', \(appids), \(on))") }
    public func setInCollection(_ id: String, _ appids: [UInt32], _ on: Bool) async throws {
        _ = try await agent("shelf(\(literal(id)), \(appids), \(on))")
    }
    /// Creates a user collection with these games, as the client's 添加至 › 新收藏… does.
    public func newCollection(_ name: String, _ appids: [UInt32]) async throws {
        _ = try await agent("newCollection(\(literal(name)), \(appids))")
    }

    /// Everything Vapor shows; `apps` (the whole library) only when asked, and nil while Steam is still loading it.
    public func snapshot(includeApps: Bool = false) async throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: try await agent("snapshot(\(includeApps))"))
    }

    /// Steam's own install path (what the library's Install button calls), with Vapor answering the wizard.
    public func install(_ appid: UInt32) async throws { _ = try await agent("install(\(appid))") }

    /// Opens the install wizard far enough to learn size and free space, then cancels. Downloads nothing.
    /// Nil while an install or another probe holds the wizard.
    public func probeInstall(_ appid: UInt32) async throws -> Install? {
        try JSONDecoder().decode(Install?.self, from: try await agent("probe(\(appid))"))
    }

    /// The user accepted every agreement shown in Vapor: record each with Steam, then continue.
    public func acceptEulas() async throws { _ = try await agent("acceptEulas()") }
    public func continueInstall() async throws { _ = try await agent("continueInstall()") }
    public func cancelInstall() async throws { _ = try await agent("cancelInstall()") }
    public func uninstall(_ appid: UInt32) async throws { _ = try await agent("uninstall(\(appid))") }
    /// Answers `Snapshot.uninstallRequest` (an uninstall Steam itself asked to confirm, e.g. steam://uninstall).
    /// Agent side only: VaporApp does not yet show `uninstallRequest` or call these, so until EngineModel adds a
    /// confirmation for it such a request is held here (no files are removed) and the user is not asked.
    public func confirmUninstall() async throws { _ = try await agent("confirmUninstall()") }
    public func declineUninstall() async throws { _ = try await agent("declineUninstall()") }
    public func pause(_ appid: UInt32) async throws { _ = try await agent("pause(\(appid))") }
    public func resume(_ appid: UInt32) async throws { _ = try await agent("resume(\(appid))") }
    public func queue(_ appid: UInt32) async throws { _ = try await agent("queue(\(appid))") }
    public func remove(_ appid: UInt32) async throws { _ = try await agent("remove(\(appid))") }
    public func move(_ appid: UInt32, to index: Int) async throws { _ = try await agent("move(\(appid), \(index))") }
    public func setDownloadsEnabled(_ on: Bool) async throws { _ = try await agent("enableAll(\(on))") }
    public func showSteamWindow(_ show: Bool) async throws { _ = try await agent("showMain(\(show))") }

    /// What Steam's game Properties dialog shows (appDetailsStore), trimmed to what Vapor edits.
    public struct AppDetails: Decodable, Sendable, Equatable {
        public let appid: UInt32
        public let name: String
        public let installed: Bool
        public let launchOptions: String
        public let languages: [Language]
        public let selectedLanguage: String
        public let cloudAvailable: Bool
        public let cloudEnabledForAccount: Bool
        public let cloudEnabled: Bool
        public let cloudUsed: String
        public let cloudFree: String
        public let autoUpdate: Int          // 0 Steam decides, 1 wait until launch, 2 high priority
        public let backgroundDownloads: Int // 0 global setting, 1 always allow, 2 never
        public let diskUsage: Int64
        public let dlcUsage: Int64
        public let buildID: Int
        public let lastUpdated: Int
        public let installFolder: String
        public let installFolderIndex: Int
        public let thirdPartyUpdater: Bool
        public let betas: [Beta]
        public let selectedBeta: String
        public let hasPrivateBetas: Bool
        public let dlc: [DLC]
        public let developer: String
        public let homepage: String
        public let playtimeMinutes: Int
        public let lastPlayed: Int
        public let workshopVisible: Bool

        public struct Language: Decodable, Sendable, Equatable, Hashable {
            public let id: String
            public let name: String
        }
        public struct Beta: Decodable, Sendable, Equatable, Hashable {
            public let name: String
            public let description: String
            public let lastUpdated: Int
        }
        public struct DLC: Decodable, Sendable, Equatable, Identifiable {
            public let id: UInt32
            public let name: String
            public let state: String
            public let enabled: Bool
            public let size: Int64
        }
    }

    public func details(_ appid: UInt32) async throws -> AppDetails? {
        try JSONDecoder().decode(AppDetails?.self, from: try await agent("details(\(appid))"))
    }

    private func literal(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self) + "[0]"
    }
    public func setLaunchOptions(_ appid: UInt32, _ options: String) async throws { _ = try await agent("call('Apps', 'SetAppLaunchOptions', \(appid), \(literal(options)))") }
    public func setLanguage(_ appid: UInt32, _ id: String) async throws { _ = try await agent("call('Apps', 'SetAppCurrentLanguage', \(appid), \(literal(id)))") }
    public func toggleCloud(_ appid: UInt32) async throws { _ = try await agent("call('Apps', 'ToggleAppSteamCloudEnabled', \(appid))") }
    public func setAutoUpdate(_ appid: UInt32, _ v: Int) async throws { _ = try await agent("call('Apps', 'SetAppAutoUpdateBehavior', \(appid), \(v))") }
    public func setBackgroundDownloads(_ appid: UInt32, _ v: Int) async throws { _ = try await agent("call('Apps', 'SetAppBackgroundDownloadsBehavior', \(appid), \(v))") }
    public func verify(_ appid: UInt32) async throws { _ = try await agent("call('Apps', 'VerifyApp', \(appid))") }
    public func setDLC(_ appid: UInt32, _ dlc: UInt32, enabled: Bool) async throws { _ = try await agent("call('Apps', 'SetDLCEnabled', \(appid), \(dlc), \(enabled))") }
    public func setBeta(_ appid: UInt32, _ name: String) async throws { _ = try await agent("call('Apps', 'JoinAppContentBeta', \(appid), \(literal(name)))") }
    public func moveInstall(_ appid: UInt32, toFolder index: Int) async throws { _ = try await agent("call('InstallFolder', 'MoveInstallFolderForApp', \(appid), \(index))") }

    // MARK: - Community

    /// One achievement as Steam's game page shows it (SteamClient.Apps.GetMyAchievementsForApp).
    public struct Achievement: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let description: String
        public let achieved: Bool
        public let unlockTime: Int
        public let icon: URL?
        public let hidden: Bool
        public let globalPercent: Double
    }

    /// Empty when the game has no achievements or Steam has not loaded its stats.
    public func achievements(_ appid: UInt32) async throws -> [Achievement] {
        try JSONDecoder().decode(Lossy.List<Achievement>.self, from: try await agent("achievements(\(appid))")).items
    }

    /// A friend from the client's friends list (friendStore).
    public struct Friend: Decodable, Sendable, Equatable, Identifiable {
        public let steamID: String
        public let name: String
        public let state: Int             // EPersonaState: 0 offline, 1 online, 2 busy, 3 away, 4 snooze …
        public let gameName: String
        public let gameAppID: UInt32
        public let avatar: URL?
        public let lastOnline: Int

        public var id: String { steamID }
        public var isOnline: Bool { state != 0 }
    }

    public func friends() async throws -> [Friend] {
        try JSONDecoder().decode(Lossy.List<Friend>.self, from: try await agent("friends()")).items
    }

    // MARK: - Steam settings

    public struct Settings: Decodable, Sendable, Equatable {
        public let downloadRegion: Int
        public let regions: [Region]
        public let throttleKbps: Int        // download_throttle_rate, 0 = unlimited
        public let rateInBits: Bool
        public let restrictAutoUpdates: Bool
        public let restrictStart: Int
        public let restrictEnd: Int
        public let downloadWhilePlaying: Bool
        public let throttleWhileStreaming: Bool
        public let shaderPrecache: Bool
        public let peerContent: Int
        public let cloudEnabled: Bool
        public let overlayEnabled: Bool     // enable_overlay: the in-game Steam overlay (Shift+Tab)
        public let language: String
        public let languages: [String]
        public let folders: [Folder]

        public struct Region: Decodable, Sendable, Equatable, Hashable {
            public let id: Int
            public let name: String
        }
    }

    public func settings() async throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: try await agent("settings()"))
    }

    /// Writes one client setting by its settingsStore name (download_region, download_throttle_rate …).
    public func setSetting(_ name: String, _ value: Any) async throws {
        let v = String(decoding: try JSONSerialization.data(withJSONObject: [value]), as: UTF8.self) + "[0]"
        _ = try await agent("setSetting(\(literal(name)), \(v))")
    }
    public func clearDownloadCache() async throws { _ = try await agent("call('Settings', 'ClearDownloadCache')") }
    public func addLibraryFolder(_ windowsPath: String) async throws { _ = try await agent("call('InstallFolder', 'AddInstallFolder', \(literal(windowsPath)))") }
    public func removeLibraryFolder(_ index: Int) async throws { _ = try await agent("call('InstallFolder', 'RemoveInstallFolder', \(index))") }
    public func setDefaultLibraryFolder(_ index: Int) async throws { _ = try await agent("call('InstallFolder', 'SetDefaultInstallFolder', \(index))") }
    public func repairLibraryFolder(_ index: Int) async throws { _ = try await agent("call('InstallFolder', 'RepairInstallFolder', \(index))") }

    /// Runs a steam:// URL inside the client.
    public func open(steamURL: String) async throws {
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: [steamURL]), as: UTF8.self)
        _ = try await evaluate("SteamClient.URL.ExecuteSteamURL(\(literal)[0]); return true;")
    }

    // MARK: - Web session

    public struct Cookie: Sendable {
        public let name, value, domain, path: String
        public let secure, httpOnly: Bool
    }

    /// The client's web login, as its built-in store browser holds it. Session cookies only; Steam
    /// refreshes them at every logon, so callers should copy them into a non-persistent store.
    public func webCookies() async throws -> [Cookie] {
        let store = try await targets().first { $0.url.hasPrefix("https://store.steampowered.com") }?.title ?? "SharedJSContext"
        let hosts = ["store.steampowered.com", "checkout.steampowered.com", "help.steampowered.com", "steamcommunity.com", "login.steampowered.com"]
        let result = try await send("Network.getCookies", params: ["urls": hosts.map { "https://\($0)/" }], target: store)
        return (result["cookies"] as? [[String: Any]] ?? []).compactMap { c in
            guard let name = c["name"] as? String, let value = c["value"] as? String, let domain = c["domain"] as? String else { return nil }
            return Cookie(name: name, value: value, domain: domain, path: c["path"] as? String ?? "/",
                          secure: c["secure"] as? Bool ?? false, httpOnly: c["httpOnly"] as? Bool ?? false)
        }
    }

    /// The store user agent the client uses, so pages render their in-client buttons (steam://launch …).
    public func storeUserAgent() async throws -> String {
        try JSONDecoder().decode(String.self, from: try await evaluate("return navigator.userAgent;"))
    }

    // MARK: - Agent

    static let agentVersion = 17

    /// Replaces the agent only when it is another version and idle: every client shares one agent, and an
    /// install or probe in flight must keep the agent that is driving it.
    static let injection = """
    window.__vaporLang = '\(AppLanguage.steam)';
    if (window.__vapor?.version !== \(agentVersion) && !window.__vapor?.busy?.()) {
    \(agentSource)
    window.__vapor.subscribe();
    }
    """

    /// Installed into SharedJSContext.
    ///
    /// Steam's install manager singleton is not global; it is found through webpack's module table by a
    /// line of its own source. Its Init registers nine client callbacks in a fixed order; the agent
    /// unregisters the install-wizard and uninstall ones (finding their slots from Init's source) and
    /// answers those callbacks itself, so Steam never opens its window. `dispose` puts Steam's back.
    /// steamui boots in stages (webpack, then the stores, then Init), so nothing here assumes it is done:
    /// the takeover is retried until it succeeds and every store read tolerates a store that is not there yet.
    static let agentSource = #"""
    window.__vapor?.dispose?.();
    window.__vapor = (() => {
      const CLIENT = '0';                       // this machine; other ids are remote-download clients
      const DONE = new Set([0, 14, 15, 16]);
      const num = v => Number(v ?? 0) || 0;
      const g = f => { try { return f(); } catch { return undefined; } };   // page globals may not be declared yet
      let run = null;                           // the install being driven right now
      let probe = null;
      let uninstallRequest = null;
      let quietUntil = 0;                       // a probe's own cancel echoes back; ignore it
      let disposed = false;

      // --- find Steam's install manager -------------------------------------------------------------
      let req = null, im = null, pushed = false, scanned = 0;
      const findModule = needle => {
        if (!req) return;
        for (const id of Object.keys(req.m)) if (String(req.m[id]).includes(needle)) return req(id);
      };
      const locate = () => {
        if (im) return true;
        if (!window.webpackChunksteamui || !window.SteamClient) return false;
        if (!pushed) { pushed = true; window.webpackChunksteamui.push([[Symbol('vapor')], {}, r => { req = r; }]); }
        const n = req ? Object.keys(req.m).length : 0;
        if (!n || n === scanned) return false;  // scan again only once more modules have loaded
        scanned = n;
        const mod = findModule('m_unAppIDExpectedInstall=');
        im = (mod && Object.values(mod).find(v => v && typeof v.InstallApp === 'function' && typeof v.GetInstallManager === 'function')) || null;
        return !!im;
      };

      const mainWindow = () => g(() => SteamUIStore.WindowStore.MainWindowInstance.BrowserWindow);
      let mainAllowed = false;                  // Vapor asked for Steam's own window (debugging); until it is hidden again
      const showMain = show => {
        const w = mainWindow()?.SteamClient?.Window; if (!w) return false;
        mainAllowed = !!show;
        if (show) { w.ShowWindow(); w.BringToFront(); } else w.HideWindow();
        return true;
      };

      // --- take over Steam's wizard callbacks ---------------------------------------------------
      const taken = { RegisterForShowInstallWizard: ['Installs', 'OnShowInstallWizard'], RegisterForShowConfirmUninstall: ['Installs', 'OnShowConfirmUninstall'],
                      RegisterForShowFailedUninstall: ['Installs', 'OnShowFailedUninstall'],
                      RegisterForGameActionUserRequest: ['Apps', 'OnGameActionUserRequest'], RegisterForGameActionShowError: ['Apps', 'OnGameActionShowError'] };
      const detached = [];
      const ours = [];
      const takeover = () => {
        if (detached.length) return true;
        if (disposed || !locate()) return false;
        const order = String(im.Init).match(/RegisterFor\w+/g) || [];
        const handles = im.m_clientHandles?.m_rgHandles || [];
        if (!order.length || order.length !== handles.length) return false;   // Init has not run yet
        for (const name of Object.keys(taken)) {
          const i = order.indexOf(name);
          if (i >= 0 && handles[i]?.unregister) { handles[i].unregister(); detached.push([name, i]); }
        }
        if (!detached.length) return false;
        for (const [name] of detached) ours.push(SteamClient[taken[name][0]][name](handlers[name]));
        im.OnShowInstallWizard({ eInstallState: 0 });   // drop any dialog Steam already had up
        im.ShowGameLaunchingDialog = () => {};          // Steam's "launching" window; the launch shows in Vapor instead
        g(() => im.m_rgShowLaunchingDialog.splice(0));
        resumeLaunches();
        emit();
        return true;
      };
      let waiting = null;
      // Resolves once the takeover is in place; gives up after 20 s (the 5 s heartbeat keeps trying).
      const ready = () => waiting ??= new Promise(done => {
        let tries = 0;
        const tick = () => {
          if (takeover()) return done(true);
          if (disposed || ++tries >= 40) { waiting = null; return done(false); }
          setTimeout(tick, 500);
        };
        tick();
      });

      const eulaContent = async e => {
        try {
          const u = new URL(e.url.replace('http://', 'https://'));
          u.searchParams.append('eulaLang', window.__vaporLang || 'schinese');   // Steam falls back to English without a translation
          u.searchParams.append('json', '1');
          const d = await (await fetch(u, { credentials: 'include' })).json();
          return { title: d.title ?? null, content: d.content ?? null };
        } catch { return { title: null, content: null }; }
      };

      const endProbe = result => { const p = probe; probe = null; clearTimeout(p.timer); p.resolve(result); };
      const onWizard = async m => {
        const state = m.eInstallState;
        const appid = num(m.currentAppID);
        if (probe) {                                // Steam has one wizard, and the probe opened it
          if (state !== 7 && !DONE.has(state) && state !== 8 && state !== 4) return;
          const p = probe; quietUntil = Date.now() + 3000;
          endProbe({ appid: appid || p.appid, state, required: num(m.nDiskSpaceRequired), available: num(m.nDiskSpaceAvailable),
                     error: num(m.eAppError), step: null, problem: null, done: false, eulas: null, keys: null });
          if (!DONE.has(state)) SteamClient.Installs.CancelInstall();
          return;
        }
        if (!run || run.done) {
          // Nothing to drive: idle, a finished wizard, or a probe's echo. A new flow never inherits an old run's eulas or problem.
          if (state === 0 || state === 14 || state === 16 || Date.now() < quietUntil) return;
          run = { appid, driven: false, step: null, problem: null, done: false, eulas: null, keys: null };
        } else if (appid && run.appid && appid !== run.appid && DONE.has(state)) return;   // another game's wizard ended
        Object.assign(run, { appid: appid || run.appid, state, required: num(m.nDiskSpaceRequired),
                             available: num(m.nDiskSpaceAvailable), error: num(m.eAppError) });
        run.done = DONE.has(state);
        if (run.done) { run.step = null; return; }
        if (state === 7) {
          run.step = null;
          if (!run.driven) {
            // A wizard nobody asked Vapor to run (steam://install, a launch that needs an install…) never starts a
            // download, and Steam's own dialog is detached, so close it and tell the user instead of leaving it open unseen.
            Object.assign(run, { problem: 'unrequested', done: true, state: 15 });
            await SteamClient.Installs.CancelInstall();
            return;
          }
          if (num(m.nDiskSpaceAvailable) > 0 && num(m.nDiskSpaceRequired) >= num(m.nDiskSpaceAvailable)) {
            run.problem = 'disk';
            await SteamClient.Installs.CancelInstall();
            return;
          }
          const folder = m.iInstallFolder >= 0 ? m.iInstallFolder : num(g(() => installFolderStore.DefaultInstallFolderIndex));
          if (m.iInstallFolder !== folder) await SteamClient.Installs.SetInstallFolder(folder);
          await SteamClient.Installs.ContinueInstall();
        } else if (state === 8) {
          run.step = 'eula';
          const list = await SteamClient.Apps.LoadEula(run.appid);
          run.eulas = await Promise.all((list || []).map(async e => ({ id: String(e.id ?? ''), url: e.url || '', version: num(e.version), ...(await eulaContent(e)) })));
          if (!run.eulas.length) { run.step = null; await SteamClient.Installs.ContinueInstall(); }
        } else if (state === 4) {
          run.step = 'cdkey';
          run.keys = (m.rgApps || []).filter(a => a.strKey).map(a => ({ appid: num(a.nAppID), name: a.strName || '', key: a.strKey }));
        } else if (state === 6) {
          run.step = 'password';
        } else if (state === 13) {
          run.step = 'signup';
        } else {
          run.step = null;
        }
      };
      const handlers = {
        RegisterForShowInstallWizard: m => {
          onWizard(m)
            // A rejected Steam call ends the run (report() then shows 无法安装), so busy() can never stick at true.
            .catch(e => { if (run && !run.done) Object.assign(run, { problem: String(e), done: true, state: 15, step: null }); })
            .finally(() => emit(!!run?.done));   // a finished install or uninstall changes the library
        },
        RegisterForShowConfirmUninstall: (apps, client) => {
          uninstallRequest = { apps: (apps || []).map(Number).filter(Number.isFinite), client: client ?? CLIENT };
          emit();
        },
        RegisterForShowFailedUninstall: (apps, err) => {
          // An install in progress keeps its own state; the failure only replaces a finished run.
          if (!run || run.done) run = { appid: num(apps?.[0]), state: 15, required: 0, available: 0, error: num(err), step: null,
                                        problem: 'uninstall', done: true, eulas: null, keys: null };
          emit(true);
        },
        // Without Vapor watching, Steam's own launch dialogs come back, so a launch never waits on nobody.
        RegisterForGameActionUserRequest: (...a) => {
          if (!attended()) return im.OnGameActionUserRequest(...a);
          onLaunchRequest(...a).catch(e => console.error('[vapor] launch request', e)).finally(() => emit());
        },
        RegisterForGameActionShowError: (...a) => { if (attended()) onLaunchError(...a); else im.OnGameActionShowError(...a); },
      };

      // --- snapshot ---------------------------------------------------------------------------
      const app = a => {
        const pcd = (a.per_client_data || []).find(c => c.clientid === CLIENT) || {};
        return { appid: num(a.appid), name: a.display_name || '', type: num(a.app_type), installed: !!pcd.installed,
                 displayStatus: num(pcd.display_status), percent: num(pcd.status_percentage),
                 sizeOnDisk: num(a.size_on_disk), minutesPlayed: num(a.minutes_playtime_forever), lastPlayed: num(a.rt_last_time_played) };
      };
      const DOWNLOAD = 2;
      const item = i => {
        const types = i.update_type_info || [];
        const stage = k => types.reduce((s, u) => s + num(u.progress?.[k]?.bytes_in_progress), 0);
        const total = k => types.reduce((s, u) => s + num(u.progress?.[k]?.bytes_total), 0);
        return { appid: num(i.appid), active: !!i.active, paused: !!i.paused, completed: !!i.completed,
                 queueIndex: i.queue_index ?? -1, deferredTime: num(i.deferred_time), completedTime: num(i.completed_time),
                 downloaded: stage(DOWNLOAD), total: total(DOWNLOAD), buildID: num(i.buildid), targetBuildID: num(i.target_buildid),
                 updateResult: num(i.update_result), contentTypes: types.map((u, k) => u.has_update ? k : -1).filter(k => k >= 0) };
      };
      const folder = f => ({ index: num(f.nFolderIndex), path: f.strFolderPath || '', free: num(f.nFreeSpace),
                             capacity: num(f.nCapacity), isDefault: !!f.bIsDefaultFolder });
      const folders = () => g(() => installFolderStore.AllInstallFolders) || [];
      const each = (list, f) => list.map(x => g(() => f(x))).filter(Boolean);   // one odd record never drops the list
      const account = () => {
        const u = g(() => App.m_CurrentUser); if (!u) return null;
        const me = g(() => friendStore.m_FriendsUIFriendStore.m_self.persona);
        return { persona: me?.m_strPlayerName || '', accountName: u.strAccountName || '', steamID: u.strSteamID || '',
                 wallet: u.strAccountBalance || '', personaState: num(me?.m_ePersonaState),
                 avatar: g(() => me.avatar_url_full || me.avatar_url_medium) || null };
      };

      // --- push: the same client callbacks downloadsStore listens to -----------------------------
      let emitTimer = null, lastApps = 0, lastItems = null, lastError = null, subscribed = false, heartbeat = null, retry = null;
      const emit = withApps => {
        if (withApps) lastApps = 0;
        if (disposed || emitTimer || typeof window.__vaporEmit !== 'function') return;
        emitTimer = setTimeout(() => {               // after Steam's own handlers updated its stores
          emitTimer = null;
          if (!g(() => downloadsStore)) return;      // steamui is still booting; the heartbeat comes back
          // Progress ticks alone do not resend the library: only a changed download list or 15 s does.
          const items = (g(() => downloadsStore.m_DownloadItems.get(CLIENT)) || []).map(i => i?.appid + ':' + !!i?.completed).join();
          const now = Date.now();
          try {
            const s = api.snapshot(items !== lastItems || now - lastApps > 15000);
            if (s.apps) { lastApps = now; lastItems = items; }
            window.__vaporEmit(JSON.stringify(s));
          } catch (e) {
            if (String(e) !== lastError) { lastError = String(e); console.error('[vapor] snapshot failed', e); }
          }
        }, 80);
      };

      // An uninstall only flips per_client_data.installed, which the download list may never show: resend the library
      // now and again while Steam removes the files.
      const refreshApps = () => { emit(true); for (const ms of [2000, 6000]) setTimeout(() => emit(true), ms); };

      // Friend chats live in the friends UI app inside this same context; account ids are SteamID64 - base.
      const BASE = 76561197960265728n;
      const friendChat = (sid, create) => g(() => g_FriendsUIApp.ChatStore.GetFriendChat(Number(BigInt(String(sid)) - BASE), create));
      const chats = () => {
        const friends = g(() => friendStore.m_FriendsUIFriendStore.all_friends) || [];
        const out = [];
        for (const f of friends) {
          const sid = g(() => String(f.persona.m_steamid.ConvertTo64BitString())) || g(() => String(f.steamid64)) || '';
          if (!sid) continue;
          const c = friendChat(sid, false);
          if (!c) continue;
          const unread = num(g(() => c.unread_message_count)), lastTime = num(g(() => c.time_last_message));
          if (unread || lastTime) out.push({ steamID: sid, unread, lastTime, last: String(g(() => c.GetLastMessage?.()) ?? c.m_strLastMessage ?? '') });
        }
        return out;
      };
      const trayEntries = () => {
        const groups = g(() => NotificationStore.GetNotificationsInTray()[0]) || [];
        const out = [];
        for (const grp of groups) for (const n of (grp?.notifications || [])) {
          const item = n?.data?.item || {};
          out.push({ id: String(n.notificationID ?? item.notification_id ?? ''), type: num(item.notification_type ?? n.eType),
                     time: num(n.rtCreated ?? item.timestamp), read: !!item.read, count: num(n.data?.rollup_count) || 1,
                     body: typeof item.body_data === 'string' ? item.body_data : JSON.stringify(item.body_data ?? {}) });
        }
        return out.sort((a, b) => b.time - a.time);
      };

      // Favourites/hidden are system collections; user collections exclude Steam's automatic ones.
      const shelves = () => {
        const ids = c => c?.apps ? Array.from(c.apps.keys ? c.apps.keys() : c.apps).map(Number).filter(Boolean) : [];
        const skip = new Set(['favorite', 'hidden', 'uncategorized']);
        return { favorites: ids(collectionStore.GetCollection('favorite')), hidden: ids(collectionStore.GetCollection('hidden')),
                 collections: (collectionStore.userCollections || []).filter(c => c && !skip.has(c.id) && !String(c.id).startsWith('type-'))
                   .map(c => ({ id: String(c.id), name: c.displayName || '', apps: ids(c), dynamic: !!c.bIsDynamic })) };
      };

      // --- sign-in: Steam's login page flow (QR and password), rebuilt from the parts it is made of -----
      // The login page's session classes are not exported, but their base class, the service calls and
      // messages are; the module ids are read from the QR class's own imports so they survive updates.
      let kit = null;
      const authKit = () => {
        if (kit) return kit;
        if (!req && window.webpackChunksteamui) { pushed = true; window.webpackChunksteamui.push([[Symbol('vapor-auth')], {}, r => { req = r; }]); }
        if (!req) return null;
        const src = id => String(req.m[id]);
        const qrId = Object.keys(req.m).find(id => src(id).includes('GetChallengeURL(){return this.m_strChallengeURL}'));
        if (!qrId) return null;
        const s = src(qrId), vars = {};
        for (const m of s.matchAll(/(\w+)=t\((\d+)\)/g)) vars[m[1]] = m[2];
        const base = s.match(/extends (\w+)\.(\w+)\{/), wrap = s.match(/(\w+)\.(\w+)\.Init\((\w+)\.(\w+)\)/),
              emsg = s.match(/SetEMsg\((\w+)\.(\w+)\)/), svc = s.match(/(\w+)\.(\w+)\.BeginAuthSessionViaQR/),
              site = s.match(/set_website_id\((\w+)\.(\w+)\.WEBSITE_ID\)/);
        if (!base || !wrap || !emsg || !svc || !site) return null;
        const msgs = req(vars[svc[1]]);
        const cls = name => Object.values(msgs).find(v => typeof v === 'function' && g(() => v.prototype.getClassName()) === name);
        const connId = Object.keys(req.m).find(id => /OnSharedConnectionEstablished/.test(src(id)) && /GetServiceTransport\(\)\{/.test(src(id)));
        const rsaId = Object.keys(req.m).find(id => src(id).includes('publickey_mod') && src(id).includes('RSAKey'));
        const k = {
          Base: req(vars[base[1]])[base[2]], Msg: req(vars[wrap[1]])[wrap[2]], EMsg: req(vars[emsg[1]])[emsg[2]], svc: msgs[svc[2]],
          website: g(() => req(vars[site[1]])[site[2]].WEBSITE_ID),
          QR: cls('CAuthentication_BeginAuthSessionViaQR_Request'), Cred: cls('CAuthentication_BeginAuthSessionViaCredentials_Request'),
          RSA: cls('CAuthentication_GetPasswordRSAPublicKey_Request'), Code: cls('CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request'),
          Conn: connId && Object.values(req(connId)).find(v => typeof v === 'function' && v.prototype?.GetServiceTransport && v.prototype?.OnSharedConnectionEstablished),
          encrypt: rsaId && Object.values(req(rsaId)).find(v => typeof v === 'function' && String(v).includes('publickey_mod')),
        };
        if (!Object.values(k).every(Boolean)) return null;
        // What the client's own login page sends as device details (platform 1 = Steam client).
        const device = async () => {
          const [os, info, host, machine] = await Promise.all([SteamClient.System.GetOSType(), SteamClient.System.GetSystemInfo(),
            g(() => SteamClient.Auth.GetLocalHostname()) ?? '', g(() => SteamClient.Auth.GetMachineID())]);
          return { os_type: os, device_friendly_name: host, machine_id: machine, platform_type: 1, gaming_device_type: info?.eGamingDeviceType };
        };
        const begin = (session, msg) => {
          const o = msg.Body().toObject();
          session.m_strClientID = o.client_id; session.m_rgRequestID = o.request_id; session.m_msPollInterval = num(o.interval) * 1000;
          return o;
        };
        k.QRSession = class extends k.Base {
          async Start() {
            await this.m_transport.MakeReady();
            const m = k.Msg.Init(k.QR); m.SetEMsg(k.EMsg);
            m.Body().set_device_details(await this.GetDeviceDetails());
            m.Body().set_website_id(k.website);
            const r = await k.svc.BeginAuthSessionViaQR(this.m_transport, m);
            if (r.GetEResult() !== 1) return r.GetEResult();
            this.m_strChallengeURL = begin(this, r).challenge_url;
            this.StartPolling(false);
            return 1;
          }
        };
        k.PasswordSession = class extends k.Base {
          async Start(account, password, remember) {
            await this.m_transport.MakeReady();
            const q = k.Msg.Init(k.RSA); q.SetEMsg(k.EMsg); q.Body().set_account_name(account);
            const kr = await k.svc.GetPasswordRSAPublicKey(this.m_transport, q);
            if (kr.GetEResult() !== 1) return kr.GetEResult();
            const key = kr.Body().toObject();
            const m = k.Msg.Init(k.Cred); m.SetEMsg(k.EMsg);
            const b = m.Body();
            b.set_account_name(account); b.set_encrypted_password(k.encrypt(password, key)); b.set_encryption_timestamp(key.timestamp);
            b.set_remember_login(!!remember); b.set_persistence(remember ? 1 : 0); b.set_website_id(k.website);
            b.set_device_details(await this.GetDeviceDetails());
            const guard = await g(() => SteamClient.Auth.GetSteamGuardData(account));
            if (guard?.eresult === 1 && guard.data) b.set_guard_data(guard.data);
            const r = await k.svc.BeginAuthSessionViaCredentials(this.m_transport, m);
            if (r.GetEResult() !== 1) return r.GetEResult();
            const o = begin(this, r);
            this.steamid = o.steamid;
            this.confirmations = (o.allowed_confirmations || []).map(c => num(c.confirmation_type));
            this.StartPolling(false);
            return 1;
          }
          async SendCode(code, type) {
            const m = k.Msg.Init(k.Code); m.SetEMsg(k.EMsg);
            const b = m.Body();
            b.set_client_id(this.m_strClientID); b.set_steamid(this.steamid); b.set_code(String(code)); b.set_code_type(type);
            return (await k.svc.UpdateAuthSessionWithSteamGuardCode(this.m_transport, m)).GetEResult();
          }
        };
        k.device = device;
        return (kit = k);
      };

      // One sign-in at a time. status: starting, waiting (QR shown / approve on phone / code needed), signingIn, done, failed.
      let login = null, loginSession = null, loginConn = null;
      const endLogin = () => { g(() => loginSession?.StopPolling()); loginSession = null; g(() => loginConn?.Disconnect?.()); loginConn = null; };
      const signIn = async r => {
        if (!login) return;
        if (!r?.bSuccess) { Object.assign(login, { status: 'failed', failure: num(g(() => loginSession.GetFailureState())) }); endLogin(); emit(); return; }
        login.status = 'signingIn'; emit();
        const res = await SteamClient.Auth.SetLoginToken(r.strRefreshToken, r.strAccountName);
        if (r.strNewGuardData) await g(() => SteamClient.Auth.SetSteamGuardData(r.strAccountName, r.strNewGuardData));
        Object.assign(login, { account: r.strAccountName, status: num(res?.result) === 1 ? 'done' : 'failed', eresult: num(res?.result) });
        endLogin(); emit();
      };
      const startLogin = async (kind, start) => {
        const k = authKit();
        if (!k) throw new Error('Steam sign-in is not available');
        endLogin();
        login = { kind, status: 'starting', challengeURL: null, account: null, confirmations: [], eresult: 0, failure: 0 };
        loginConn = new k.Conn();
        const transport = loginConn.GetServiceTransport();
        g(() => loginConn.Connect());
        const session = kind === 'qr' ? new k.QRSession(transport, signIn, k.device) : new k.PasswordSession(transport, signIn, k.device);
        loginSession = session;
        const e = await start(session);
        if (loginSession !== session) return login;
        if (e !== 1) { Object.assign(login, { status: 'failed', eresult: e }); endLogin(); }
        else Object.assign(login, { status: 'waiting', challengeURL: session.m_strChallengeURL ?? null, confirmations: session.confirmations ?? [] });
        emit();
        return login;
      };
      const loginState = () => login && { ...login, challengeURL: loginSession?.m_strChallengeURL ?? login.challengeURL,
                                           remote: !!g(() => loginSession.BHadRemoteInteraction()) };
      // The client's own login window stays hidden; Vapor shows its sign-in instead.
      const hideLoginWindow = () => {
        const wins = g(() => SteamUIStore.WindowStore.SteamUIWindows) || [];
        let hidden = false;
        for (const w of wins) if (g(() => w.IsDesktopLoginWindow())) { g(() => w.BrowserWindow.SteamClient.Window.HideWindow()); hidden = true; }
        return hidden;
      };

      // --- Steam's own windows and questions, answered in Vapor ---------------------------------------
      // Every popup Steam opens is created hidden, and every modal is recorded; what asks the user something
      // becomes a dialog in the snapshot, answered with answerDialog(). Clients ping; when none has for a
      // while (Vapor quit), nothing is taken over, so Steam stays usable on its own.
      let lastPing = 0;
      const attended = () => Date.now() - lastPing < 15000;
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const fill = (s, args) => args.reduce((t, a, i) => t.split('%' + (i + 1) + '$s').join(String(a ?? '')), s);
      // Steam's text for one of its tokens, with the token so Vapor can show its Chinese string instead.
      const T = (key, ...args) => ({ text: fill(String(g(() => LocalizationManager.LocalizeString('#' + key)) ?? key), args), key, args: args.map(a => String(a ?? '')) });
      let reverse = null;
      // Text read back from Steam's page; the token is found when the text is exactly one of Steam's strings.
      const plain = s => {
        s = String(s ?? '').trim();
        if (!s) return null;
        if (!reverse?.size) {
          reverse = new Map();
          // Several tokens share a text ("Close"); the plain button and dialog ones read best in Chinese too.
          const plainKey = k => /^(Button_|Generic_|Dialog_)/.test(k);
          for (const [k, v] of g(() => LocalizationManager.m_mapTokens) || []) {
            if (typeof v !== 'string') continue;
            const t = v.trim(), had = reverse.get(t);
            if (had == null || (plainKey(k) && !plainKey(had))) reverse.set(t, k);
          }
        }
        return { text: s, key: reverse.get(s) ?? null, args: [] };
      };
      const choice = (id, label, role = null) => ({ id: String(id), label, role });

      // Ids stay unique across agent versions, so a client's record of what it answered never matches a newer dialog.
      let dialogs = [], dialogSeq = 0;
      const dialogBase = Date.now().toString(36);
      const addDialog = d => { d.id = dialogBase + '-' + (++dialogSeq); dialogs.push(d); emit(); return d; };
      const dropDialog = d => { const i = dialogs.indexOf(d); if (i >= 0) { dialogs.splice(i, 1); emit(); } };
      const dialogJSON = d => ({ id: d.id, kind: d.kind, appid: num(d.appid), title: d.title ?? null, message: (d.message || []).filter(Boolean),
        note: d.note ?? null, buttons: d.buttons || [], eulas: d.eulas ?? null, keys: d.keys ?? null, code: num(d.code), details: d.details ?? null,
        localTime: num(d.localTime), remoteTime: num(d.remoteTime), remember: d.remember ?? null });

      // Buttons of a rendered Steam dialog, outermost clickable elements with a label (window controls have none).
      const readDom = root => {
        if (!root) return null;
        const all = [...root.querySelectorAll('button, .DialogButton, [role=button]')].filter(b => !b.closest('.ModalPosition_Dismiss'));
        const els = all.filter(b => !all.some(o => o !== b && o.contains(b)) && (b.innerText || '').trim());
        const labels = new Set(els.map(b => b.innerText.trim()));
        const header = root.querySelector('.DialogHeader, [class*=DialogHeader]')?.innerText?.trim() || null;
        const text = root.innerText || '';
        const lines = [...new Set(text.split('\n').map(s => s.trim()).filter(s => s && !labels.has(s) && s !== header))];
        return { header, lines, buttons: els.map(b => ({ el: b, label: plain(b.innerText), disabled: !!b.disabled })), length: text.length };
      };
      const fromDom = (d, root) => {
        const c = readDom(root);
        if (!c || (!c.buttons.length && !c.lines.length)) return false;
        d.root = root;
        if (c.header) d.title = plain(c.header);
        if (c.lines.length) d.message = c.lines.slice(0, 12).map(plain);
        if (c.buttons.length) d.buttons = c.buttons.map((b, i) => choice('button:' + i, b.label, b.disabled ? 'disabled' : null));
        return true;
      };
      // Clicks the button as it is rendered now, so Steam's own handler decides what happens.
      const click = (d, c) => {
        const i = Number(String(c).split(':')[1]);
        const b = readDom(d.root?.isConnected ? d.root : d.popup?.window?.document?.body)?.buttons[i];
        if (!b || b.disabled) return false;
        b.el.click();
        return true;
      };
      // A click that did not close the dialog (a tab, a checkbox) puts it back, as it looks now.
      const recheck = d => setTimeout(() => {
        if (d.closed || dialogs.includes(d) || disposed) return;
        const root = d.popup ? d.popup.window?.document?.body : d.root;
        if (root?.isConnected === false) return;
        fromDom(d, root);
        dialogs.push(d); emit();
      }, 700);

      // --- game launches ---------------------------------------------------------------------------
      const launches = new Map();               // gameActionID → state
      let launchTimer = null;
      const appOf = gameid => num(g(() => appStore.GetAppOverviewByGameID(String(gameid))?.appid)) || num(gameid);
      const nameOf = appid => g(() => appStore.GetAppOverviewByAppID(appid)?.display_name) || '';
      const pollLaunches = () => {
        if (launchTimer || disposed) return;
        launchTimer = setInterval(() => {
          if (!launches.size) { clearInterval(launchTimer); launchTimer = null; return; }
          for (const [id, l] of launches) g(() => SteamClient.Apps.GetGameActionDetails(id, d => {
            const next = { done: num(parseInt(d?.strNumDone)), total: num(parseInt(d?.strNumTotal)), secondsRemaining: num(d?.nSecondsRemaing) };
            if (next.done !== l.done || next.total !== l.total || next.secondsRemaining !== l.secondsRemaining) { Object.assign(l, next); emit(); }
          }));
        }, 1000);
      };
      const launchStarted = (id, gameid, action) => {
        if (action !== 'LaunchApp' || launches.has(id)) return;
        launches.set(id, { gameActionID: num(id), appid: appOf(gameid), task: 'Starting', details: '', request: null, done: 0, total: 0, secondsRemaining: 0 });
        pollLaunches(); emit();
      };
      const launchTask = (id, gameid, action, task, details) => {
        const l = launches.get(id); if (!l) return;
        Object.assign(l, { task: String(task || ''), details: String(details || '') });
        if (l.request === 'ProcessingShaderCache' && task !== 'ProcessingShaderCache') l.request = null;
        emit();
      };
      const launchEnded = id => {
        launches.delete(id);
        for (const d of dialogs.filter(d => d.gameActionID === id)) dropDialog(d);
        emit();
      };
      // Steam's "always launch this way": its launch-option chooser keeps the chosen nIndex in the client's local
      // storage under Apps\<appid>\DefaultLaunchOption\<hash of the options>, so a changed option list asks again.
      // The storage class and the hash come out of the chooser module's own imports, so they survive updates.
      let optionStore = null;
      const launchOptionStore = () => {
        if (optionStore) return optionStore;
        locate();
        const id = Object.keys(req?.m || {}).find(k => String(req.m[k]).includes('DefaultLaunchOption'));
        if (!id) return null;
        const src = String(req.m[id]);
        const imported = name => { const m = src.match(new RegExp('[,;\\s]' + name.replace(/\$/g, '\\$') + '=t\\((\\d+)\\)')); return m && req(m[1]); };
        const st = src.match(/useMemo\(\(\)=>new ([\w$]+)\.([\w$]+),\[\]\)/);
        const hs = src.match(/\(0,([\w$]+)\.([\w$]+)\)\(JSON\.stringify\([\w$]+\)\)/);
        const Store = st && imported(st[1])?.[st[2]], hash = hs && imported(hs[1])?.[hs[2]];
        if (!Store || !hash) return null;
        const store = new Store();
        return optionStore = { store, key: (appid, opts) => 'Apps\\' + appid + '\\DefaultLaunchOption\\' + (hash(JSON.stringify(opts)) >>> 0).toString(16) };
      };
      // The remembered option's nIndex, or -1 (nothing remembered, or the list no longer has it).
      const savedLaunchOption = async (appid, opts) => {
        try {
          const o = launchOptionStore(); if (!o) return -1;
          const saved = await o.store.GetString(o.key(appid, opts));
          const n = parseInt(saved);
          return saved?.length && opts.some(x => num(x.nIndex) === n) ? n : -1;
        } catch { return -1; }
      };
      // What the chooser's Play button does: remembered when the box is ticked, forgotten otherwise.
      const rememberLaunchOption = async (appid, opts, nIndex, on) => {
        try {
          const o = launchOptionStore(); if (!o) return;
          if (on) await o.store.StoreString(o.key(appid, opts), String(nIndex)); else await o.store.RemoveObject(o.key(appid, opts));
        } catch (e) { console.error('[vapor] launch option', e); }
      };
      const optionLabel = o => {
        const d = String(o.strDescription || '');
        return d.startsWith('#') ? T(d.slice(1), o.strGameName || '') : plain(d || o.strGameName) ?? T('GameAction_Play');
      };
      // What Steam's LaunchApp action asks for, as its own dialogs would (CLaunchGameAction.OnGameActionUserRequest).
      const onLaunchRequest = async (id, gameid, action, task, details) => {
        const appid = appOf(gameid), name = nameOf(appid);
        const l = launches.get(id); if (l) l.request = task;
        const go = v => { if (l) l.request = null; SteamClient.Apps.ContinueGameAction(id, String(v)); g(() => SteamUIStore.SetRunningApp(appid)); };
        const ask = (kind, title, message, buttons, extra = {}) => addDialog({
          kind, appid, gameActionID: id, title, message, ...extra.fields,
          buttons: extra.noCancel ? buttons : [...buttons, choice('cancel', extra.cancel ?? T('Button_Cancel'), 'cancel')],
          answer: async (c, remember) => {
            if (c === 'cancel' || c === 'dismiss') { if (!extra.noCancel) return SteamClient.Apps.CancelGameAction(id); c = buttons[0].id; remember = false; }
            await extra.accept?.(c, remember);
            go(c);
          } });
        switch (task) {
          case 'CreatingProcess': case 'ShowInterstitials': return go(task);
          case 'ShowEula': {
            const list = (await SteamClient.Apps.LoadEula(appid)) || [];
            if (!list.length) return go(task);
            const eulas = await Promise.all(list.map(async e => ({ id: String(e.id ?? ''), url: e.url || '', version: num(e.version), ...(await eulaContent(e)) })));
            return ask('eula', T('EulaDialog_Header'), [T('Installer_Eula', name)], [choice(task, T('Installer_EulaAccept'), 'default')],
              { fields: { eulas }, accept: async () => { for (const e of eulas) await SteamClient.Apps.MarkEulaAccepted(appid, e.id, e.version); } });
          }
          case 'ShowLaunchOption': {
            const opts = (await SteamClient.Apps.GetLaunchOptionsForApp(appid)) || [];
            const saved = await savedLaunchOption(appid, opts);
            if (saved >= 0) return go(saved);
            if (opts.length === 1) return go(opts[0].nIndex);
            return ask('launchOption', plain(name) ?? T('GameAction_Play'), [T('LaunchOptionsDialog_MakeSelection', name)],
              opts.map((o, i) => choice(num(o.nIndex), optionLabel(o), i === 0 ? 'default' : null)),
              { fields: { note: T('LaunchOptionsDialog_SeeProperties'), remember: T('LaunchOptionsDialog_Remember') },
                accept: (c, remember) => rememberLaunchOption(appid, opts, c, !!remember) });
          }
          case 'ShowVROculusOnly':
            return ask('confirm', T('Steam_OculusOnlyGameWarning_Title'), [T(parseInt(details) ? 'Steam_OculusOnlyGameWarning_Desc' : 'Steam_IncorrectVRSDKWarning_Desc', name)],
              [choice('1', T('Button_OK'), 'default')]);
          case 'RunningInstallScript':
            return ask('confirm', T('LaunchApp_InstallScript_Failed_Title'), [T('LaunchApp_InstallScript_Failed_Text')],
              [choice('IgnoreInstallError', T('LaunchApp_InstallScript_Failed_Continue'), 'default')]);
          case 'KickingOtherSession':
            return ask('confirm', T('LaunchApp_OtherSessionPlaying_Title'), [T('LaunchApp_OtherSessionPlaying_Text', name, details)],
              [choice('KickOtherSession', T('LaunchApp_ContineLaunch'), 'destructive')]);
          case 'ShowGameArgs':
            return ask('confirm', T('LaunchApp_ShowGameArgs_Title'), [T('LaunchApp_ShowGameArgs_Text', name, details)],
              [choice(task, T('LaunchApp_ContineLaunch'), 'default')], { fields: { details: String(details || '') } });
          case 'SynchronizingCloud': case 'SynchronizingControllerConfig': {
            const controller = task === 'SynchronizingControllerConfig';
            if (details === 'cloudconflict') {
              let t = null;
              if (!controller) try { t = await SteamClient.Apps.GetConflictingFileTimestamps(appid); } catch {}
              return ask('cloudConflict', T(controller ? 'CloudConflict_ControllerConfigs_Header' : 'CloudConflict_AppLaunch_Header'),
                [controller ? T('CloudConflict_ControllerConfigs_Description') : T('CloudConflict_AppLaunch_Description', name)],
                [choice('KeepLocal', T(controller ? 'CloudConflict_ControllerConfigs_KeepLocal' : 'CloudConflict_KeepLocal')),
                 choice('KeepRemote', T(controller ? 'CloudConflict_ControllerConfigs_KeepRemote' : 'CloudConflict_KeepRemote'))],
                { fields: { note: T('CloudConflict_AppLaunch_Footer_Note'), localTime: t?.rtLocalTime, remoteTime: t?.rtRemoteTime } });
            }
            if (details === 'syncfailed')
              return ask('cloudSyncFailed', T('CloudSyncFailed_AppLaunch_Header'), [T('CloudSyncFailed_AppLaunch_Warning', name), T('CloudSyncFailed_AppLaunch_Description')],
                [choice('IgnoreCloud', T('CloudSyncFailed_AppLaunch_Continue'), 'destructive')], { cancel: T('CloudSyncFailed_AppLaunch_Cancel') });
            if (details === 'pendingcloudsessions')
              return ask('cloudPending', T('CloudPendingOps_Header'), [T('CloudPendingOps_Description')],
                [choice('IgnorePendingCloudSessions', T('CloudPendingOps_Continue'), 'destructive')], { cancel: T('CloudPendingOps_Cancel') });
            return go(details);
          }
          case 'ShowDurationControl': {
            const body = { WaitingVerification: 'DurationControl_PlaytimeExceeded_Body_WaitingVerification', Maintenance: 'DurationControl_PlaytimeExceeded_Body_Maintenance',
                           CheckFailed: 'Error_ErrorCommunicatingWithNetwork' }[details] || 'DurationControl_PlaytimeExceeded_Body_Night';
            return ask('confirm', T('DurationControl_PlaytimeExceeded_Title'), [T(body)], [choice('', T('Button_Continue'), 'default')]);
          }
          case 'ProcessingShaderCache': return;    // progress in `launches`; skipShaders() answers it
          case 'ShowCDKey': {
            await g(() => SteamClient.Apps.RequestLegacyCDKeysForApp(appid));
            let keys = [];
            for (let i = 0; i < 10 && !keys.length; i++) {
              keys = (g(() => appDetailsStore.GetAppDetails(appid)?.vecLegacyCDKeys) || []).filter(k => k?.strKey && k?.strName && k.eResult === 1)
                .map(k => ({ appid, name: String(k.strName), key: String(k.strKey) }));
              if (!keys.length) await sleep(300);
            }
            return ask('cdkey', T('GameAction_ShowCDKeys'), [T('GameAction_ShowCDKeys_Desc_NoCopy', name)],
              [choice('', T('Generic_Close'), 'default'), choice('DontShowAgain', T('GameAction_ShowCDKeys_DontShowAgain'))], { fields: { keys }, noCancel: true });
          }
          default:
            return ask('generic', plain(name) ?? T('Dialog_DefaultWindowTitle'), [plain(task + (details ? ' (' + details + ')' : ''))],
              [choice(task, T('Button_Continue'), 'default')]);
        }
      };
      // CLaunchGameAction.ShowAppLaunchErrorDialogInternal: Steam's reason for EAppUpdateError `code`.
      const onLaunchError = (id, gameid, action, code, details) => {
        const appid = appOf(gameid), reason = T('Steam_AppUpdateError_' + num(code));
        addDialog({ kind: 'launchError', appid, gameActionID: id, code, details: details ? String(details) : null,
                    title: plain(nameOf(appid)) ?? T('Dialog_DefaultWindowTitle'),
                    message: [details ? T('AppLaunchError_Text_Long', reason.text, details) : T('AppLaunchError_Text', reason.text)],
                    buttons: [choice('ok', T('Button_OK'), 'default')], answer: async () => {} });
        emit();
      };
      // A purchase a game asks the user to approve (the overlay's microtransaction page). Steam's own page lives in the
      // game's overlay, which nobody sees here; its text is fetched with the user's session and shown as a dialog, and the
      // buttons call what the page's own steam://close/authorize and steam://close/cancel links call.
      const PRICE = /[$¥￥€£]\s?\d|\d[\d.,]*\s?(?:CNY|RMB|USD|EUR|GBP|元)|\b(?:CNY|RMB|USD|EUR)\b/;
      const parseMicroTxn = html => {
        const doc = new DOMParser().parseFromString(String(html ?? ''), 'text/html');
        for (const e of doc.querySelectorAll('script, style, noscript, header, footer, nav, select, button, a[href^="steam:"]')) e.remove();
        for (const e of doc.querySelectorAll('br, p, div, tr, li, h1, h2, h3, h4, td, th')) e.append('\n');
        const lines = [...new Set((doc.body?.textContent || '').split('\n').map(l => l.replace(/\s+/g, ' ').trim()).filter(Boolean))];
        return { price: lines.filter(l => PRICE.test(l)).slice(0, 3), lines: lines.filter(l => !PRICE.test(l)).slice(0, 8) };
      };
      const microTxn = async (appid, trans, url) => {
        if (!attended()) return;
        let page = { price: [], lines: [] };
        try { if (url) page = parseMicroTxn(await (await fetch(String(url).replace(/^http:/, 'https:'), { credentials: 'include' })).text()); } catch {}
        for (const d of dialogs.filter(d => d.kind === 'microtxn' && String(d.trans) === String(trans))) dropDialog(d);
        const done = async approve => { await SteamClient.User[approve ? 'AuthorizeMicrotxn' : 'CancelMicrotxn'](trans); };
        const d = { kind: 'microtxn', appid: num(appid), trans, title: T('Overlay_MicroTxnAuth_Title'), message: page.lines.map(plain),
                    details: page.price.join('\n') || null,
                    // No default role: Enter must never approve a purchase. Only the explicit button approves;
                    // closing the sheet cancels, as closing the overlay does.
                    buttons: [choice('authorize', { text: 'Authorize', key: null, args: [] }), choice('cancel', T('Button_Cancel'), 'cancel')],
                    answer: async c => done(c === 'authorize') };
        addDialog(d);
      };
      const microTxnDismissed = (appid, trans) => { for (const d of dialogs.filter(d => d.kind === 'microtxn' && String(d.trans) === String(trans))) dropDialog(d); };

      // Launches already under way when the agent arrives; one waiting for an answer is asked again.
      const resumeLaunches = async () => {
        let list = [];
        try { list = (await SteamClient.Apps.GetActiveGameActions()) || []; } catch {}
        for (const a of list) {
          if (a.strActionName !== 'LaunchApp') continue;
          launchStarted(a.nGameActionID, a.gameid, a.strActionName);
          launchTask(a.nGameActionID, a.gameid, a.strActionName, a.strTaskName, a.strTaskDetails);
          if (a.bWaitingForUI && attended() && !dialogs.some(d => d.gameActionID === a.nGameActionID))
            handlers.RegisterForGameActionUserRequest(a.nGameActionID, a.gameid, a.strActionName, a.strTaskName, a.strTaskDetails);
        }
      };

      // --- popups: created hidden; dialogs read back from their page ------------------------------
      const hidden = new Set();
      let popupHooks = null, modalPatch = null, pendingModal = null, mainGuard = null, navHook = null;
      const windows = [];                       // Steam windows kept hidden lately, for Vapor to show its own counterpart
      const toasts = [];                        // Steam's notification toasts, for Vapor to post as its own
      // What each kind of Steam window becomes. `close` is how long after it opened Steam's window is closed (Vapor has
      // its own page for it, and a window left open also never reports a second steam://open); null leaves it alone
      // because Steam still needs it. `event` windows are recorded for Vapor to navigate to its counterpart. Anything not
      // listed is recorded as "other" and closed after ten idle minutes, so hidden windows do not pile up.
      const WINDOWS = [
        { kind: 'marketing', title: ['LibraryHome_MarketingMessages', 'PendingGifts_Title', 'SteamUI_ValveSurvey_Title'], close: 0 },
        { kind: 'settings', title: ['Settings_Title'], close: 1500, event: true },
        { kind: 'friends', name: /^friendslist/, title: ['WindowTitle_FriendsList'], close: 1500, event: true },
        { kind: 'chat', name: /^(chat_|ChatWindow_)/, close: 1500, event: true },
        { kind: 'toast', name: /^notificationtoasts_/, close: null },       // Steam closes its own toast
        { kind: 'login', title: ['SignIn_Title'], close: null },            // the client's sign-in; hideLoginWindow keeps it hidden
        { kind: 'microtxn', name: /^(MTX)?OverlayBrowser_|^MTXOverlayBrowser_/, close: null },   // an in-game purchase approval
      ];
      const OTHER_IDLE_MS = 10 * 60 * 1000;
      let lastWindowAt = 0;
      const recordWindow = w => {
        lastWindowAt = Math.max(Date.now(), lastWindowAt + 1);
        windows.push({ title: null, ...w, time: Math.floor(Date.now() / 1000), at: lastWindowAt });
        windows.splice(0, Math.max(0, windows.length - 10));
        emit();
      };
      const isMenu = p => /^contextmenu_/.test(g(() => p.GetName()) || '');
      const keepHidden = p => {
        if (hidden.has(p) || isMenu(p) || p.window === mainWindow() || mainAllowed || !attended()) return;
        hidden.add(p);
        p.m_bCreateHidden = true;               // RenderInternal shows a popup unless it was created hidden
        p.Focus = () => {};                     // and re-shows an existing one through Focus
        const w = p.window;
        p.__vaporVisibility = () => { if (w?.document?.visibilityState === 'visible') g(() => w.SteamClient.Window.HideWindow()); };
        g(() => w.document.addEventListener('visibilitychange', p.__vaporVisibility));
        g(() => p.__vaporVisibility());
        const modal = pendingModal && Date.now() - pendingModal.at < 2000 ? pendingModal.d : null;
        if (modal) { pendingModal = null; modal.popup = p; return; }
        setTimeout(() => describePopup(p), 700);
      };
      // Never closed behind Steam's back: the main window, a window that holds a question Vapor shows (its answer closes
      // it), the client's sign-in, and anything while Steam shuts down.
      const keepOpen = p => {
        if (p.window === mainWindow() || num(g(() => SteamUIStore.m_shutdownState.eShutdownState)) !== 0) return true;
        const doc = g(() => p.window.document);
        if (dialogs.some(d => d.popup === p || (d.root && d.root.ownerDocument === doc))) return true;
        return !!g(() => SteamUIStore.WindowStore.SteamUIWindows.some(w => w.IsDesktopLoginWindow() && w.BrowserWindow === p.window));
      };
      const closeWindow = (p, ms) => setTimeout(() => { if (!disposed && !g(() => p.BIsClosed()) && !keepOpen(p)) g(() => p.Close()); }, ms);
      // The friend a chat window is with, when its title (the friend's name) names exactly one friend.
      const chatPeer = title => {
        const name = title?.text;
        const found = name ? (g(() => friendStore.m_FriendsUIFriendStore.all_friends) || []).filter(f => g(() => f.persona.m_strPlayerName) === name) : [];
        return found.length === 1 ? g(() => String(found[0].persona.m_steamid.ConvertTo64BitString())) ?? null : null;
      };
      const readToast = (p, name, again) => {
        const doc = g(() => p.window.document), c = doc && readDom(doc.body);
        const lines = c ? c.lines.slice(0, 4).map(plain) : [];
        if (!lines.length) { if (!again) setTimeout(() => readToast(p, name, true), 800); return; }
        toasts.push({ id: name, appid: num(name.match(/^notificationtoasts_uid(\d+)/)?.[1]), lines, time: Math.floor(Date.now() / 1000) });
        toasts.splice(0, Math.max(0, toasts.length - 10));
        emit();
      };
      const describePopup = p => {
        if (disposed || g(() => p.BIsClosed())) return;
        const doc = g(() => p.window.document); if (!doc) return;
        if (dialogs.some(d => d.root?.ownerDocument === doc)) return;   // a modal inside it already asks
        const title = plain(p.m_strTitle || doc.title), name = g(() => p.GetName()) || '';
        const rule = WINDOWS.find(r => r.name?.test(name) || (title?.key && r.title?.includes(title.key)));
        if (rule?.kind === 'toast') return readToast(p, name);
        if (rule && rule.close == null) return;
        if (rule?.kind === 'marketing') { g(() => p.Close()); return; }
        // Tooltips, toasts and menus never ask anything; only dialog markup with a few buttons is a question,
        // anything else is a window (settings, friends list, chat) Vapor has its own page for.
        const quiet = num(p.m_rgParams?.eCreationFlags) & (4 | 512 | 65536);
        const dialogLike = doc.body.classList.contains('ModalDialogBody') || !!doc.querySelector('.ModalPosition, .DialogContent');
        const c = readDom(doc.body);
        const shuttingDown = num(g(() => SteamUIStore.m_shutdownState.eShutdownState)) !== 0;
        if (!rule && !quiet && dialogLike && !shuttingDown && c && c.buttons.length && c.buttons.length <= 6 && c.length < 2000) {
          const d = { kind: 'generic', title, message: [], buttons: [], popup: p,
                      answer: async ch => { if (ch !== 'dismiss' && click(d, ch)) return recheck(d); g(() => p.Close()); } };
          fromDom(d, doc.body);
          if (!c.header && title) d.title = title;
          addDialog(d);
        } else {
          recordWindow({ title, kind: rule?.kind ?? 'other', steamID: rule?.kind === 'chat' ? chatPeer(title) : null });
          closeWindow(p, rule ? rule.close : OTHER_IDLE_MS);
        }
      };
      const released = p => {
        hidden.delete(p);
        for (const d of dialogs.filter(d => d.popup === p)) { d.closed = true; dropDialog(d); }
      };
      // Generic modals (ShowGenericConfirmDialog and the like) carry their text and callbacks as props.
      const propButtons = props => [
        ...(props.onOK ? [choice('ok', plain(props.strOKButtonText) ?? T('Button_OK'), 'default')] : []),
        ...(props.onCancel ? [choice('cancel', plain(props.strCancelButtonText) ?? T('Button_Cancel'), 'cancel')] : []),
      ];
      const trackModal = (el, handle, title) => {
        if (disposed || !el || mainAllowed || !attended() || el.props?.className === 'Hidden') return;   // the stand-in a popped-out modal leaves behind
        const props = el.props || {};
        const d = { kind: 'generic', appid: num(props.appid ?? props.appID), handle, props,
                    title: plain(title) ?? plain(props.strTitle), message: [plain(props.strDescription)], buttons: propButtons(props),
                    answer: async c => {
                      if (c.startsWith('button:') && click(d, c)) return recheck(d);
                      if (c === 'ok') await props.onOK?.(); else await props.onCancel?.();
                      g(() => handle.Close());
                      // A popup that only hosts this dialog (About, legacy popouts) goes with it, as its close box would do.
                      const host = ownerPopup(d.root);
                      if (host && g(() => host.window.document.body.classList.contains('ModalDialogBody'))) g(() => host.Close());
                    } };
        if (title != null) pendingModal = { d, at: Date.now() };
        const before = new Set(modalRoots());
        g(() => handle.ClosedPromise.then(() => { d.closed = true; dropDialog(d); }));
        addDialog(d);
        // In-window modals render into the (hidden) owner window's ModalPosition; popped-out ones into their own popup.
        setTimeout(() => {
          if (d.closed || disposed) return;
          let root = d.popup ? g(() => d.popup.window.document.body) : null;
          if (!root) {
            const found = modalRoots().filter(e => !claimed.has(e) && !before.has(e));
            const said = String(props.strTitle || props.strDescription || '');
            root = (said && found.find(e => e.innerText.includes(said))) || found[found.length - 1] || null;
            if (root) claimed.add(root);
          }
          if (!root || !fromDom(d, root)) return;
          for (const x of dialogs.filter(x => x !== d && !x.handle && x.root?.ownerDocument === root.ownerDocument)) dropDialog(x);
          emit();
        }, 500);
      };
      const claimed = new WeakSet();
      const modalRoots = () => [document, ...Array.from(g(() => g_PopupManager.GetPopups()) || []).map(p => g(() => p.window.document)).filter(Boolean)]
        .flatMap(doc => [...doc.querySelectorAll('.ModalPosition')]);
      const ownerPopup = root => root && Array.from(hidden).find(p => g(() => p.window.document) === root.ownerDocument);
      const hookModals = () => {
        if (modalPatch) return;
        if (!locate()) return;
        const mod = findModule('m_rgLegacyPopupModals=[]');
        const P = mod && Object.values(mod).find(v => typeof v === 'function' && v.prototype?.ShowLegacyPopupModal)?.prototype;
        if (!P?.ShowModalInternal) return;
        const inline = P.ShowModalInternal, legacy = P.ShowLegacyPopupModal;
        P.ShowModalInternal = function (el) { const h = inline.apply(this, arguments); g(() => trackModal(el, h, null)); return h; };
        P.ShowLegacyPopupModal = function (title, el) { const h = legacy.apply(this, arguments); g(() => trackModal(el, h, String(title ?? ''))); return h; };
        modalPatch = { P, inline, legacy, ours: [P.ShowModalInternal, P.ShowLegacyPopupModal] };
      };
      // Steam shows its main window on its own now and then (a second steam.exe, steam://open/main); hide it again.
      const guardMain = () => {
        const w = mainWindow();
        if (!w || mainGuard?.w === w) return;
        mainGuard?.off();
        const on = () => {
          const visible = w.document.visibilityState === 'visible';
          if (!visible) mainAllowed = false;
          else if (!mainAllowed && attended()) g(() => w.SteamClient.Window.HideWindow());
        };
        g(() => w.document.addEventListener('visibilitychange', on));
        mainGuard = { w, off: () => g(() => w.document.removeEventListener('visibilitychange', on)) };
      };
      // Steam navigates its (hidden) main window for steam://nav and steam://store links; the page it goes to is an
      // event for Vapor to show its own counterpart. The first half minute is Steam settling in, not a request.
      const routeEvent = loc => {
        const path = String(loc?.pathname || ''), url = String(loc?.state?.strURL || '');
        let m;
        if (path.startsWith('/library/downloads')) return { kind: 'downloads' };
        if ((m = path.match(/^\/library\/(?:app|collection\/[^/]+)\/(\d+)/))) return { kind: 'library', appid: num(m[1]) };
        if (path.startsWith('/library')) return { kind: 'library' };
        if (path.startsWith('/settings')) return { kind: 'settings' };
        if (path.startsWith('/browser') && url) {
          if ((m = url.match(/^https?:\/\/store\.steampowered\.com\/(?:agecheck\/)?app\/(\d+)/))) return { kind: 'store', appid: num(m[1]), url };
          return { kind: /^https?:\/\/store\.steampowered\.com\//.test(url) ? 'store' : 'other', url };
        }
        return null;
      };
      let lastNav = null;
      const hookNav = () => {
        const h = g(() => SteamUIStore.WindowStore.MainWindowInstance.m_history);
        if (!h?.listen || navHook?.h === h) return;
        navHook?.off();
        const since = Date.now();
        const off = h.listen((a, b) => g(() => {
          const action = a?.action ?? b;
          if (disposed || !attended() || action === 'REPLACE' || Date.now() - since < 30000) return;
          const e = routeEvent(a?.location ?? a); if (!e) return;
          const key = JSON.stringify(e);
          if (lastNav?.key === key && Date.now() - lastNav.at < 2000) return;
          lastNav = { key, at: Date.now() };
          recordWindow(e);
        }));
        navHook = { h, off: typeof off === 'function' ? off : () => {} };
      };
      const hookWindows = () => {
        if (disposed) return;
        guardMain();
        hookNav();
        hookModals();
        if (!window.g_PopupManager) return;
        popupHooks ??= [g_PopupManager.AddPopupCreatedCallback(p => g(() => keepHidden(p))),
                        g_PopupManager.AddPopupDestroyedCallback(p => g(() => released(p)))];
        // Also catches a popup some other path showed (heartbeat).
        if (!attended() || mainAllowed) return;
        for (const p of Array.from(g_PopupManager.GetPopups())) {
          if (isMenu(p) || p.window === mainWindow() || !g(() => p.BIsVisible())) continue;
          keepHidden(p);
          g(() => p.window.SteamClient.Window.HideWindow());
        }
      };
      const releaseWindows = () => {
        for (const h of popupHooks || []) g(() => h.Unregister());
        popupHooks = null;
        for (const p of hidden) { delete p.Focus; g(() => p.window.document.removeEventListener('visibilitychange', p.__vaporVisibility)); }
        hidden.clear();
        if (modalPatch) {
          const { P, inline, legacy, ours: [a, b] } = modalPatch;
          if (P.ShowModalInternal === a) P.ShowModalInternal = inline;
          if (P.ShowLegacyPopupModal === b) P.ShowLegacyPopupModal = legacy;
          modalPatch = null;
        }
        mainGuard?.off(); mainGuard = null;
        navHook?.off(); navHook = null;
        clearInterval(launchTimer);
      };

      const api = {
        version: \#(agentVersion),
        busy() { return !!probe || !!(run?.driven && !run.done); },
        subscribe() {
          if (!subscribed && !window.SteamClient) {
            retry ??= setTimeout(() => { retry = null; api.subscribe(); }, 500);
            return true;
          }
          if (!subscribed) {
            subscribed = true;
            ours.push(SteamClient.Downloads.RegisterForDownloadItems(() => emit()));
            ours.push(SteamClient.Downloads.RegisterForDownloadOverview(() => emit()));
            ours.push(SteamClient.InstallFolder.RegisterForInstallFolderChanges(() => emit()));
            ours.push(SteamClient.GameSessions?.RegisterForAppLifetimeNotifications?.(() => emit()));
            ours.push(SteamClient.Apps.RegisterForGameActionStart(launchStarted));
            ours.push(SteamClient.Apps.RegisterForGameActionTaskChange(launchTask));
            ours.push(SteamClient.Apps.RegisterForGameActionEnd(launchEnded));
            ours.push(g(() => SteamClient.Overlay.RegisterForMicroTxnAuth((appid, trans, flags, url) => { microTxn(appid, trans, url).catch(e => console.error('[vapor] microtxn', e)); })));
            ours.push(g(() => SteamClient.Overlay.RegisterForMicroTxnAuthDismiss(microTxnDismissed)));
            for (const n of ['RegisterForShutdownStart', 'RegisterForShutdownState', 'RegisterForShutdownFailed', 'RegisterForShutdownDone'])
              ours.push(g(() => SteamClient.User[n](() => emit())));
            heartbeat = setInterval(() => { takeover(); hookWindows(); emit(); }, 5000);
          }
          hookWindows();
          ready();
          emit(true);
          return true;
        },
        dispose() {
          disposed = true;
          clearInterval(heartbeat); clearTimeout(retry); clearTimeout(emitTimer);
          if (probe) { SteamClient.Installs.CancelInstall(); endProbe(null); }   // the probe owns the open wizard
          for (const h of ours) h?.unregister?.();
          const handles = im?.m_clientHandles?.m_rgHandles;
          if (handles) for (const [name, i] of detached) handles[i] = SteamClient[taken[name][0]][name](im[taken[name][1]].bind(im));
          if (im) delete im.ShowGameLaunchingDialog;
          releaseWindows();
        },
        snapshot(includeApps) {
          const ds = g(() => downloadsStore);
          const ov = g(() => ds.m_DownloadOverview.get(CLIENT));
          const items = g(() => ds.m_DownloadItems.get(CLIENT)) || [];
          const hist = (g(() => ds.m_DownloadHistory.get(CLIENT)) || []).filter(h => h?.rt_sample_time);
          const all = includeApps ? g(() => collectionStore.allGamesCollection.allApps) : null;
          const login = g(() => App.m_eLoginState);
          return {
            loggedIn: login != null ? !!g(() => App.m_CurrentUser.strSteamID) : !!g(() => collectionStore.allGamesCollection.allApps.length),
            account: account(),
            downloadsPaused: !!ov?.paused,
            downloads: each(items, item),
            overview: g(() => ov && ov.update_appid ? { appid: num(ov.update_appid), state: ov.update_state || 'None', paused: !!ov.paused,
              networkBytesPerSecond: num(ov.update_network_bytes_per_second), peakBytesPerSecond: num(ov.update_peak_network_bytes_per_second),
              diskBytesPerSecond: num(ov.update_disc_bytes_per_second), percent: num(ov.overall_percent_complete),
              secondsRemaining: num(ov.overall_estimated_time_remaining_sec), startTime: num(ov.update_start_time),
              isInstall: !!ov.update_is_install, isWorkshop: !!ov.update_is_workshop, isShader: !!ov.update_is_shader,
              stages: (ov.progress || []).map(p => ({ done: num(p?.bytes_in_progress), total: num(p?.bytes_total) })) } : null) ?? null,
            history: hist.slice(-180).map(h => ({ time: num(h.rt_sample_time), network: num(h.network_bytes_per_second), disk: num(h.disc_bytes_per_second) })),
            install: run && { appid: num(run.appid), state: run.state ?? 1, required: num(run.required), available: num(run.available),
              error: num(run.error), step: run.step, problem: run.problem, done: run.done, eulas: run.eulas, keys: run.keys },
            uninstallRequest: uninstallRequest?.apps ?? null,
            running: (g(() => SteamUIStore.RunningApps) || []).map(a => num(a?.appid)).filter(Boolean),
            folders: each(folders().filter(f => f?.bIsMounted), folder),
            apps: Array.isArray(all) ? each(all, app) : null,
            detached: detached.map(d => d[0]),
            shelves: Array.isArray(all) ? g(shelves) ?? null : null,
            chats: g(chats) ?? null,
            unreadNotifications: g(() => trayEntries().filter(n => !n.read).reduce((s, n) => s + n.count, 0)) ?? null,
            login: g(loginState) ?? null,
            dialogs: dialogs.map(dialogJSON),
            launches: Array.from(launches.values()).map(l => ({ ...l })),
            shutdown: g(() => { const st = SteamUIStore.m_shutdownState; return st?.eShutdownState ? { state: num(st.eShutdownState), reason: num(st.eShutdownReason),
              appid: num(st.appid), allowForceQuit: !!st.bAllowForceQuit, failed: !!st.bFailed } : null; }) ?? null,
            windows: windows.slice(),
            toasts: toasts.slice(),
          };
        },
        async install(appid) {
          if (!await ready()) throw new Error('install manager not found');
          if (probe) endProbe(null);                 // InstallApp replaces the probe's wizard; it must not capture this one
          run = { appid, driven: true, state: 1, step: null, problem: null, done: false, eulas: null, keys: null };
          im.InstallApp(appid, CLIENT);
          emit();
          return true;
        },
        async probe(appid) {
          if (!await ready() || api.busy()) return null;   // never hijack an install or orphan another probe
          return new Promise(resolve => {
            const mine = { appid, resolve };
            mine.timer = setTimeout(() => { if (probe === mine) { probe = null; SteamClient.Installs.CancelInstall(); resolve(null); } }, 20000);
            probe = mine;
            SteamClient.Installs.OpenInstallWizard([appid], CLIENT);
          });
        },
        async acceptEulas() {
          if (!run?.eulas) return false;
          for (const e of run.eulas) await SteamClient.Apps.MarkEulaAccepted(run.appid, e.id, e.version);
          Object.assign(run, { driven: true, step: null });
          await SteamClient.Installs.ContinueInstall();
          return true;
        },
        // The user answered a step in Vapor, so from here on the agent drives this wizard.
        async continueInstall() { if (run) Object.assign(run, { driven: true, step: null }); await SteamClient.Installs.ContinueInstall(); return true; },
        async cancelInstall() { await SteamClient.Installs.CancelInstall(); if (run) { run.step = null; run.done = true; run.state = 16; } emit(); return true; },
        uninstall(appid) { uninstallRequest = null; SteamClient.Installs.OpenUninstallWizard([appid], CLIENT, true); refreshApps(); return true; },
        // What Steam's own confirm dialog calls on OK.
        confirmUninstall() {
          const r = uninstallRequest; uninstallRequest = null;
          if (r?.apps.length) SteamClient.Installs.OpenUninstallWizard(r.apps, r.client, true);
          refreshApps();
          return !!r;
        },
        declineUninstall() { uninstallRequest = null; emit(); return true; },
        pause(appid) { SteamClient.Downloads.PauseAppUpdate(appid, CLIENT); return true; },
        resume(appid) { SteamClient.Downloads.ResumeAppUpdate(appid, CLIENT); return true; },
        queue(appid) { SteamClient.Downloads.QueueAppUpdate(appid, CLIENT); return true; },
        remove(appid) { SteamClient.Downloads.RemoveFromDownloadList(appid, CLIENT); return true; },
        move(appid, index) { SteamClient.Downloads.SetQueueIndex(appid, index, CLIENT); return true; },
        enableAll(on) { SteamClient.Downloads.EnableAllDownloads(on, CLIENT); return true; },
        showMain,
        // Clients call this every few seconds; see attended().
        ping() { const was = attended(); lastPing = Date.now(); if (!was) hookWindows(); return true; },
        async answerDialog(id, c, remember) {
          const d = dialogs.find(x => x.id === String(id));
          if (!d) return false;
          dropDialog(d);
          await d.answer(String(c), !!remember);
          return true;
        },
        parseMicroTxn,
        skipShaders(id) { SteamClient.Apps.ContinueGameAction(Number(id), 'SkipShaders'); return true; },
        cancelLaunch(id) { SteamClient.Apps.CancelGameAction(Number(id)); return true; },
        loginQR() { return startLogin('qr', s => s.Start()); },
        loginPassword(account, password, remember) {
          return startLogin('password', s => s.Start(String(account).trim(), String(password), !!remember));
        },
        async loginCode(code, type) {
          if (!loginSession?.SendCode) throw new Error('no sign-in waiting for a code');
          const e = await loginSession.SendCode(code, Number(type));
          if (e !== 1 && login) login.eresult = e;
          emit();
          return e;
        },
        loginCancel() { endLogin(); login = null; emit(); return true; },
        hideLoginWindow() { return hideLoginWindow(); },
        async loginUsers() {
          return ((await SteamClient.User.GetLoginUsers()) || []).map(u => ({ accountName: String(u.accountName || ''), persona: String(u.personaName || ''),
            avatar: u.avatarUrl || null, remember: !!u.rememberPassword, lastLogin: num(u.rtLastLogin) }));
        },
        // These restart the client; the arguments keep it headless and reachable (Steam passes them on).
        switchUser(account, args) { g(() => SteamClient.User.SetRestartArgs(String(args))); SteamClient.User.RestartAsUser(String(account)); return true; },
        signOut(args) { g(() => SteamClient.User.SetRestartArgs(String(args))); SteamClient.User.SignOutAndRestart(); return true; },
        addAccount(args) { g(() => SteamClient.User.SetRestartArgs(String(args))); SteamClient.User.RestartToLoginScreen(); return true; },
        async forgetUser(account) { await SteamClient.User.RemoveUser(String(account)); return true; },
        async chat(sid) {
          const c = friendChat(sid, true);
          if (!c) return [];
          if (!c.m_bChatLogsLoaded) { await g(() => c.LoadChatLogs()); await new Promise(r => setTimeout(r, 600)); }
          const me = num(g(() => friendStore.m_FriendsUIFriendStore.self.accountid));
          return (c.chat_messages || []).slice(-300).map(m => ({ fromMe: num(m.unAccountID) === me, text: String(m.strMessage ?? ''),
                                                                 time: num(m.rtTimestamp), failed: !!m.eErrorSending }));
        },
        async sendChat(sid, text) {
          const c = friendChat(sid, true);
          if (!c) throw new Error('no chat with ' + sid);
          await c.SendChatMessage(String(text));
          emit();
          return true;
        },
        readChat(sid) { const c = friendChat(sid, false); g(() => c?.AckChatMsg?.()); emit(); return true; },
        notifications() { return trayEntries(); },
        notificationsViewed() { g(() => NotificationStore.Viewed()); emit(); return true; },
        setPersona(state) {
          const ok = [0, 1, 3, 7];
          if (!ok.includes(Number(state))) throw new Error('not allowed: persona ' + state);
          friendStore.m_FriendsUIFriendStore.SetUserPersonaState(Number(state), true);
          emit();
          return true;
        },
        shelf(id, appids, on) {
          const ids = (appids || []).map(Number).filter(Number.isFinite);
          if (id === 'favorite') collectionStore.SetAppsAsFavorite(ids, !!on);
          else if (id === 'hidden') collectionStore.SetAppsAsHidden(ids, !!on);
          else collectionStore.AddOrRemoveApp(ids, !!on, String(id));
          emit(true);
          return true;
        },
        async newCollection(name, appids) {
          const apps = (appids || []).map(id => appStore.GetAppOverviewByAppID(Number(id))).filter(Boolean);
          const c = collectionStore.NewUnsavedCollection(String(name).trim(), undefined, apps);
          await collectionStore.SaveCollection(c);
          emit(true);
          return true;
        },
        // Whitelisted pass-through for Properties/Settings setters (namespace, method, args…).
        async call(ns, method, ...args) {
          const ok = { Apps: ['SetAppLaunchOptions', 'SetAppCurrentLanguage', 'ToggleAppSteamCloudEnabled', 'SetAppAutoUpdateBehavior',
                              'SetAppBackgroundDownloadsBehavior', 'VerifyApp', 'SetDLCEnabled', 'JoinAppContentBeta'],
                       InstallFolder: ['MoveInstallFolderForApp', 'AddInstallFolder', 'RemoveInstallFolder', 'SetDefaultInstallFolder', 'RepairInstallFolder'],
                       Settings: ['ClearDownloadCache'] };
          if (!ok[ns]?.includes(method)) throw new Error('not allowed: ' + ns + '.' + method);
          const r = await SteamClient[ns][method](...args);
          emit(true);
          return r ?? true;
        },
        async details(appid) {
          const store = g(() => appDetailsStore);
          if (!store) return null;
          let d = store.GetAppDetails?.(appid);
          if (!d) {
            d = await new Promise(resolve => {
              const h = SteamClient.Apps.RegisterForAppDetails(appid, x => { h.unregister(); resolve(x); });
              setTimeout(() => resolve(store.GetAppDetails?.(appid) || null), 5000);
            });
          }
          if (!d) return null;
          return { appid, name: d.strDisplayName || '', installed: !!d.bHasAnyLocalContent, launchOptions: d.strLaunchOptions || '',
            languages: (d.vecLanguages || []).map(l => ({ id: l.strShortName || '', name: l.strDisplayName || l.strShortName || '' })),
            selectedLanguage: d.selectedLanguage?.strShortName || '',
            cloudAvailable: !!d.bCloudAvailable, cloudEnabledForAccount: !!d.bCloudEnabledForAccount, cloudEnabled: !!d.bCloudEnabledForApp,
            cloudUsed: d.strCloudBytesUsed || '', cloudFree: d.strCloudBytesAvailable || '',
            autoUpdate: num(d.eAutoUpdateValue), backgroundDownloads: num(d.eBackgroundDownloads),
            diskUsage: num(d.lDiskUsageBytes), dlcUsage: num(d.lDlcUsageBytes), buildID: num(d.nBuildID), lastUpdated: num(d.rtLastUpdated),
            installFolder: d.strInstallFolder || '', installFolderIndex: d.iInstallFolder ?? -1, thirdPartyUpdater: !!d.bIsThirdPartyUpdater,
            betas: (d.vecBetas || []).map(b => ({ name: b.strName || '', description: b.strDescription || '', lastUpdated: num(b.rtLastUpdated) })),
            selectedBeta: d.strSelectedBeta || 'public', hasPrivateBetas: !!d.bHasLockedPrivateBetas,
            dlc: (d.vecDLC || []).map(x => ({ id: num(x.unAppID), name: x.strName || '', state: x.strState || '', enabled: !!x.bEnabled, size: num(x.lDiskUsageBytes) })),
            developer: d.strDeveloperName || '', homepage: d.strHomepageURL || '', playtimeMinutes: num(d.nPlaytimeForever), lastPlayed: num(d.rtLastTimePlayed),
            workshopVisible: !!d.bWorkshopVisible };
        },
        async settings() {
          const cs = g(() => settingsStore.clientSettings) || {};
          const regions = g(() => settingsStore.settings.vecValidDownloadRegions) || [];
          let langs = [];
          try { langs = await SteamClient.Settings.GetAvailableLanguages(); } catch {}
          let lang = '';
          try { lang = await SteamClient.Settings.GetCurrentLanguage(); } catch {}
          return { downloadRegion: num(cs.download_region), regions: regions.map(r => ({ id: num(r.nRegionID), name: r.strRegionName || String(r.nRegionID) })),
            throttleKbps: num(cs.download_throttle_rate), rateInBits: !!cs.download_rate_bits_per_s,
            restrictAutoUpdates: !!cs.restrict_auto_updates, restrictStart: num(cs.restrict_auto_updates_start), restrictEnd: num(cs.restrict_auto_updates_end),
            downloadWhilePlaying: !!cs.download_while_app_running, throttleWhileStreaming: !!cs.download_throttle_while_streaming,
            shaderPrecache: !!cs.enable_shader_precache, peerContent: num(cs.download_peer_content), cloudEnabled: !!cs.cloud_enabled, overlayEnabled: cs.enable_overlay !== false,
            language: String(lang || ''), languages: (langs || []).map(String), folders: each(folders(), folder) };
        },
        setSetting(name, value) {
          const allowed = ['download_region', 'download_throttle_rate', 'download_rate_bits_per_s', 'restrict_auto_updates',
                           'restrict_auto_updates_start', 'restrict_auto_updates_end', 'download_while_app_running',
                           'download_throttle_while_streaming', 'enable_shader_precache', 'download_peer_content', 'cloud_enabled',
                           'enable_overlay'];
          if (!allowed.includes(name)) throw new Error('not allowed: ' + name);
          locate();
          // Steam's own writer: serializes {name: value} as CMsgClientSettings and calls SetSetting(base64).
          const w = findModule('SteamClient.Settings.SetSetting(X)');
          const write = w && Object.values(w).find(f => typeof f === 'function' && String(f).includes('SetSetting('));
          if (!write) throw new Error('settings writer not found');
          write(name, value);
          return true;
        },
        async achievements(appid) {
          const r = await SteamClient.Apps.GetMyAchievementsForApp(String(appid));
          return each(r?.data?.rgAchievements || [], a => ({ id: a.strID || '', name: a.strName || '', description: a.strDescription || '',
            achieved: !!a.bAchieved, unlockTime: num(a.rtUnlocked), icon: a.strImage || null, hidden: !!a.bHidden, globalPercent: num(a.flAchieved) }));
        },
        friends() {
          return each(g(() => friendStore.m_FriendsUIFriendStore.all_friends) || [], f => {
            const p = f.persona;
            return { steamID: String(f.steamid64 ?? ''), name: f.display_name || '', state: num(p.m_ePersonaState),
                     gameName: f.current_game_name || '', gameAppID: num(p.m_unGamePlayedAppID),
                     avatar: p.BHasAvatarSet?.() ? p.avatar_url_medium || null : null, lastOnline: num(p.m_rtLastSeenOnline) };
          });
        },
      };
      ready();
      return api;
    })();
    """#
}

// MARK: - Lenient decoding

// Steam's objects are loosely typed. A missing, null or odd field takes its type's empty value and an
// unreadable list element is dropped, so one strange record never loses a whole snapshot.

private protocol Blank { static var blank: Self { get } }
extension Bool: Blank { fileprivate static var blank: Bool { false } }
extension Int: Blank { fileprivate static var blank: Int { 0 } }
extension Int64: Blank { fileprivate static var blank: Int64 { 0 } }
extension UInt32: Blank { fileprivate static var blank: UInt32 { 0 } }
extension Double: Blank { fileprivate static var blank: Double { 0 } }
extension String: Blank { fileprivate static var blank: String { "" } }

private enum Lossy {
    struct Item<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }
    struct List<T: Decodable>: Decodable {
        let items: [T]
        init(from decoder: Decoder) throws { items = try [Item<T>](from: decoder).compactMap(\.value) }
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable & Blank>(_ key: Key) -> T { (try? decodeIfPresent(T.self, forKey: key)) ?? .blank }
    func optional<T: Decodable>(_ key: Key) -> T? { try? decodeIfPresent(T.self, forKey: key) }
    func list<T: Decodable>(_ key: Key) -> [T] { optionalList(key) ?? [] }
    func optionalList<T: Decodable>(_ key: Key) -> [T]? { (optional(key) as [Lossy.Item<T>]?)?.compactMap(\.value) }
}

// In extensions so the memberwise initializers stay. A hand-written init(from:) on a Decodable-only type
// gets no synthesized CodingKeys, hence the explicit ones.

extension SteamUI.App {
    enum CodingKeys: String, CodingKey { case appid, name, type, installed, displayStatus, percent, sizeOnDisk, minutesPlayed, lastPlayed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appid = c.value(.appid); name = c.value(.name); type = c.value(.type); installed = c.value(.installed)
        displayStatus = c.value(.displayStatus); percent = c.value(.percent); sizeOnDisk = c.value(.sizeOnDisk)
        minutesPlayed = c.value(.minutesPlayed); lastPlayed = c.value(.lastPlayed)
    }
}

extension SteamUI.Download {
    enum CodingKeys: String, CodingKey {
        case appid, active, paused, completed, queueIndex, deferredTime, completedTime, downloaded, total, buildID, targetBuildID
        case updateResult, contentTypes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appid = c.value(.appid); active = c.value(.active); paused = c.value(.paused); completed = c.value(.completed)
        queueIndex = c.optional(.queueIndex) ?? -1; deferredTime = c.value(.deferredTime); completedTime = c.value(.completedTime)
        downloaded = c.value(.downloaded); total = c.value(.total); buildID = c.value(.buildID); targetBuildID = c.value(.targetBuildID)
        updateResult = c.value(.updateResult); contentTypes = c.list(.contentTypes)
    }
}

extension SteamUI.Overview {
    enum CodingKeys: String, CodingKey {
        case appid, state, paused, networkBytesPerSecond, peakBytesPerSecond, diskBytesPerSecond, percent, secondsRemaining
        case startTime, isInstall, isWorkshop, isShader, stages
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appid = c.value(.appid); state = c.optional(.state) ?? "None"; paused = c.value(.paused)
        networkBytesPerSecond = c.value(.networkBytesPerSecond); peakBytesPerSecond = c.value(.peakBytesPerSecond)
        diskBytesPerSecond = c.value(.diskBytesPerSecond); percent = c.value(.percent); secondsRemaining = c.value(.secondsRemaining)
        startTime = c.value(.startTime); isInstall = c.value(.isInstall); isWorkshop = c.value(.isWorkshop); isShader = c.value(.isShader)
        stages = c.list(.stages)
    }
}

extension SteamUI.Overview.Stage {
    enum CodingKeys: String, CodingKey { case done, total }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = c.value(.done); total = c.value(.total)
    }
}

extension SteamUI.Sample {
    enum CodingKeys: String, CodingKey { case time, network, disk }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = c.value(.time); network = c.value(.network); disk = c.value(.disk)
    }
}

extension SteamUI.Install {
    enum CodingKeys: String, CodingKey { case appid, state, required, available, error, step, problem, done, eulas, keys }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appid = c.value(.appid); state = c.value(.state); required = c.value(.required); available = c.value(.available)
        error = c.value(.error); step = c.optional(.step); problem = c.optional(.problem); done = c.value(.done)
        eulas = c.optionalList(.eulas); keys = c.optionalList(.keys)
    }
}

extension SteamUI.Install.Eula {
    enum CodingKeys: String, CodingKey { case id, url, version, title, content }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); url = c.value(.url); version = c.value(.version); title = c.optional(.title); content = c.optional(.content)
    }
}

extension SteamUI.Install.Key {
    enum CodingKeys: String, CodingKey { case appid, name, key }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appid = c.value(.appid); name = c.value(.name); key = c.value(.key)
    }
}

extension SteamUI.Folder {
    enum CodingKeys: String, CodingKey { case index, path, free, capacity, isDefault }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.value(.index); path = c.value(.path); free = c.value(.free); capacity = c.value(.capacity); isDefault = c.value(.isDefault)
    }
}

extension SteamUI.Account {
    enum CodingKeys: String, CodingKey { case persona, accountName, steamID, wallet, personaState, avatar }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persona = c.value(.persona); accountName = c.value(.accountName); steamID = c.value(.steamID); wallet = c.value(.wallet)
        personaState = c.value(.personaState); avatar = c.optional(.avatar)
    }
}

extension SteamUI.LoginUser {
    enum CodingKeys: String, CodingKey { case accountName, persona, avatar, remember, lastLogin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountName = c.value(.accountName); persona = c.value(.persona); avatar = c.optional(.avatar)
        remember = c.value(.remember); lastLogin = c.value(.lastLogin)
    }
}

extension SteamUI.Login {
    enum CodingKeys: String, CodingKey { case kind, status, challengeURL, account, confirmations, eresult, failure, remote }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind); status = c.value(.status); challengeURL = c.optional(.challengeURL); account = c.optional(.account)
        confirmations = c.list(.confirmations); eresult = c.value(.eresult); failure = c.value(.failure); remote = c.value(.remote)
    }
}

extension SteamUI.ChatSummary {
    enum CodingKeys: String, CodingKey { case steamID, unread, lastTime, last }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steamID = c.value(.steamID); unread = c.value(.unread); lastTime = c.value(.lastTime); last = c.value(.last)
    }
}

extension SteamUI.ChatMessage {
    enum CodingKeys: String, CodingKey { case fromMe, text, time, failed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromMe = c.value(.fromMe); text = c.value(.text); time = c.value(.time); failed = c.value(.failed)
    }
}

extension SteamUI.Notification {
    enum CodingKeys: String, CodingKey { case id, type, time, read, count, body }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); type = c.value(.type); time = c.value(.time); read = c.value(.read); count = c.value(.count); body = c.value(.body)
    }
}

extension SteamUI.Snapshot {
    enum CodingKeys: String, CodingKey {
        case loggedIn, account, downloadsPaused, downloads, overview, history, install, uninstallRequest, running, folders, apps
        case detached, shelves, chats, unreadNotifications, login, dialogs, launches, shutdown, windows, toasts
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loggedIn = c.value(.loggedIn); account = c.optional(.account); downloadsPaused = c.value(.downloadsPaused)
        downloads = c.list(.downloads); overview = c.optional(.overview); history = c.list(.history); install = c.optional(.install)
        uninstallRequest = c.optionalList(.uninstallRequest); running = c.optionalList(.running); folders = c.list(.folders)
        apps = c.optionalList(.apps); detached = c.list(.detached); shelves = c.optional(.shelves)
        chats = c.optionalList(.chats); unreadNotifications = c.optional(.unreadNotifications)
        login = c.optional(.login)
        dialogs = c.optionalList(.dialogs); launches = c.optionalList(.launches); shutdown = c.optional(.shutdown)
        windows = c.optionalList(.windows); toasts = c.optionalList(.toasts)
    }
}

extension SteamUI.Dialog {
    enum CodingKeys: String, CodingKey { case id, kind, appid, title, message, note, buttons, eulas, keys, code, details, localTime, remoteTime, remember }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); kind = c.optional(.kind) ?? "generic"; appid = c.value(.appid); title = c.optional(.title)
        message = c.list(.message); note = c.optional(.note); buttons = c.list(.buttons); eulas = c.optionalList(.eulas)
        keys = c.optionalList(.keys); code = c.value(.code); details = c.optional(.details)
        localTime = c.value(.localTime); remoteTime = c.value(.remoteTime); remember = c.optional(.remember)
    }
}

extension SteamUI.Dialog.Text {
    enum CodingKeys: String, CodingKey { case text, key, args }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.value(.text); key = c.optional(.key); args = c.list(.args)
    }
}

extension SteamUI.Dialog.Choice {
    enum CodingKeys: String, CodingKey { case id, label, role }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); role = c.optional(.role)
        label = c.optional(.label) ?? SteamUI.Dialog.Text(text: id, key: nil, args: [])
    }
}

extension SteamUI.Launch {
    enum CodingKeys: String, CodingKey { case gameActionID, appid, task, details, request, done, total, secondsRemaining }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameActionID = c.value(.gameActionID); appid = c.value(.appid); task = c.value(.task); details = c.value(.details)
        request = c.optional(.request); done = c.value(.done); total = c.value(.total); secondsRemaining = c.value(.secondsRemaining)
    }
}

extension SteamUI.Shutdown {
    enum CodingKeys: String, CodingKey { case state, reason, appid, allowForceQuit, failed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.value(.state); reason = c.value(.reason); appid = c.value(.appid); allowForceQuit = c.value(.allowForceQuit); failed = c.value(.failed)
    }
}

extension SteamUI.HiddenWindow {
    enum CodingKeys: String, CodingKey { case title, time, kind, at, url, steamID, appid }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.optional(.title); time = c.value(.time); at = c.value(.at); url = c.optional(.url)
        let appid: UInt32? = c.optional(.appid)
        switch c.optional(.kind) as String? {
        case "settings": kind = .settings
        case "friends": kind = .friends
        case "chat": kind = .chat(steamID: c.optional(.steamID))
        case "downloads": kind = .downloads
        case "library": kind = .library(appid: appid)
        case "store": kind = .store(appid: appid)
        default: kind = .other
        }
    }
}

extension SteamUI.Toast {
    enum CodingKeys: String, CodingKey { case id, appid, lines, time }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); appid = c.value(.appid); lines = c.list(.lines); time = c.value(.time)
    }
}

extension SteamUI.Shelves {
    enum CodingKeys: String, CodingKey { case favorites, hidden, collections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = c.list(.favorites); hidden = c.list(.hidden); collections = c.list(.collections)
    }
}

extension SteamUI.Shelves.Collection {
    enum CodingKeys: String, CodingKey { case id, name, apps, dynamic }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); name = c.value(.name); apps = c.list(.apps); dynamic = c.value(.dynamic)
    }
}

extension SteamUI.AppDetails {
    enum CodingKeys: String, CodingKey {
        case appid, name, installed, launchOptions, languages, selectedLanguage, cloudAvailable, cloudEnabledForAccount
        case cloudEnabled, cloudUsed, cloudFree, autoUpdate, backgroundDownloads, diskUsage, dlcUsage, buildID, lastUpdated
        case installFolder, installFolderIndex, thirdPartyUpdater, betas, selectedBeta, hasPrivateBetas, dlc, developer, homepage
        case playtimeMinutes, lastPlayed, workshopVisible
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appid = c.value(.appid); name = c.value(.name); installed = c.value(.installed); launchOptions = c.value(.launchOptions)
        languages = c.list(.languages); selectedLanguage = c.value(.selectedLanguage)
        cloudAvailable = c.value(.cloudAvailable); cloudEnabledForAccount = c.value(.cloudEnabledForAccount); cloudEnabled = c.value(.cloudEnabled)
        cloudUsed = c.value(.cloudUsed); cloudFree = c.value(.cloudFree); autoUpdate = c.value(.autoUpdate); backgroundDownloads = c.value(.backgroundDownloads)
        diskUsage = c.value(.diskUsage); dlcUsage = c.value(.dlcUsage); buildID = c.value(.buildID); lastUpdated = c.value(.lastUpdated)
        installFolder = c.value(.installFolder); installFolderIndex = c.optional(.installFolderIndex) ?? -1; thirdPartyUpdater = c.value(.thirdPartyUpdater)
        betas = c.list(.betas); selectedBeta = c.optional(.selectedBeta) ?? "public"; hasPrivateBetas = c.value(.hasPrivateBetas)
        dlc = c.list(.dlc); developer = c.value(.developer); homepage = c.value(.homepage)
        playtimeMinutes = c.value(.playtimeMinutes); lastPlayed = c.value(.lastPlayed); workshopVisible = c.value(.workshopVisible)
    }
}

extension SteamUI.AppDetails.Language {
    enum CodingKeys: String, CodingKey { case id, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); name = c.value(.name)
    }
}

extension SteamUI.AppDetails.Beta {
    enum CodingKeys: String, CodingKey { case name, description, lastUpdated }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name); description = c.value(.description); lastUpdated = c.value(.lastUpdated)
    }
}

extension SteamUI.AppDetails.DLC {
    enum CodingKeys: String, CodingKey { case id, name, state, enabled, size }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); name = c.value(.name); state = c.value(.state); enabled = c.value(.enabled); size = c.value(.size)
    }
}

extension SteamUI.Settings {
    enum CodingKeys: String, CodingKey {
        case downloadRegion, regions, throttleKbps, rateInBits, restrictAutoUpdates, restrictStart, restrictEnd
        case downloadWhilePlaying, throttleWhileStreaming, shaderPrecache, peerContent, cloudEnabled, overlayEnabled, language, languages, folders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadRegion = c.value(.downloadRegion); regions = c.list(.regions); throttleKbps = c.value(.throttleKbps); rateInBits = c.value(.rateInBits)
        restrictAutoUpdates = c.value(.restrictAutoUpdates); restrictStart = c.value(.restrictStart); restrictEnd = c.value(.restrictEnd)
        downloadWhilePlaying = c.value(.downloadWhilePlaying); throttleWhileStreaming = c.value(.throttleWhileStreaming)
        shaderPrecache = c.value(.shaderPrecache); peerContent = c.value(.peerContent); cloudEnabled = c.value(.cloudEnabled)
        overlayEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .overlayEnabled)) ?? true
        language = c.value(.language); languages = c.list(.languages); folders = c.list(.folders)
    }
}

extension SteamUI.Settings.Region {
    enum CodingKeys: String, CodingKey { case id, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); name = c.value(.name)
    }
}

extension SteamUI.Achievement {
    enum CodingKeys: String, CodingKey { case id, name, description, achieved, unlockTime, icon, hidden, globalPercent }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id); name = c.value(.name); description = c.value(.description); achieved = c.value(.achieved)
        unlockTime = c.value(.unlockTime); icon = c.optional(.icon); hidden = c.value(.hidden); globalPercent = c.value(.globalPercent)
    }
}

extension SteamUI.Friend {
    enum CodingKeys: String, CodingKey { case steamID, name, state, gameName, gameAppID, avatar, lastOnline }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steamID = c.value(.steamID); name = c.value(.name); state = c.value(.state); gameName = c.value(.gameName)
        gameAppID = c.value(.gameAppID); avatar = c.optional(.avatar); lastOnline = c.value(.lastOnline)
    }
}

/// Serializes connection setup; hands out the open connection.
private actor Link {
    private var current: CDPConnection?
    private var opening: Task<CDPConnection, Error>?

    nonisolated var isOpen: Bool { openFlag.value }
    private let openFlag = Flag()

    func connection(_ ui: SteamUI) async throws -> CDPConnection {
        if let c = current, !c.isClosed { return c }
        if let opening { return try await opening.value }
        let task = Task { try await ui.open() }
        opening = task
        defer { opening = nil }
        do {
            let c = try await task.value
            current = c
            // A socket that dropped before onClose was set is caught by isClosed.
            c.onClose = { [openFlag] in openFlag.value = false }
            openFlag.value = !c.isClosed
            return c
        } catch {
            openFlag.value = false
            throw error
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

private final class Subscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SteamUI.Snapshot) -> Void)?
    func set(_ h: @escaping @Sendable (SteamUI.Snapshot) -> Void) { lock.lock(); handler = h; lock.unlock() }
    func deliver(_ s: SteamUI.Snapshot) { lock.lock(); let h = handler; lock.unlock(); h?(s) }
}

/// A CEF DevTools websocket with request/response matching and event delivery.
final class CDPConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false
    private var eventHandler: (@Sendable (String, [String: Any]) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?

    // Set on the caller's thread, read on URLSession's.
    var onEvent: (@Sendable (String, [String: Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return eventHandler }
        set { lock.lock(); eventHandler = newValue; lock.unlock() }
    }
    var onClose: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closeHandler }
        set { lock.lock(); closeHandler = newValue; lock.unlock() }
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        task.resume()
        receive()
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                let data: Data
                switch message {
                case let .string(s): data = Data(s.utf8)
                case let .data(d): data = d
                @unknown default: data = Data()
                }
                self.handle(data)
                self.receive()
            case let .failure(error):
                self.close(error)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = obj["id"] as? Int {
            lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
            if let error = obj["error"] as? [String: Any] {
                waiter?.resume(throwing: SteamUI.Failure.script(error["message"] as? String ?? "\(error)"))
            } else {
                waiter?.resume(returning: obj["result"] as? [String: Any] ?? [:])
            }
        } else if let method = obj["method"] as? String {
            onEvent?(method, obj["params"] as? [String: Any] ?? [:])
        }
    }

    /// A call that awaits a promise may legitimately run long, so its timeout only fails that call; any
    /// other call timing out means the session is dead, and closing it makes the next call reconnect.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 45) async throws -> [String: Any] {
        let closeOnTimeout = params["awaitPromise"] as? Bool != true
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            if closed { lock.unlock(); cont.resume(throwing: SteamUI.Failure.unreachable); return }
            let id = nextID
            nextID += 1
            waiters[id] = cont
            lock.unlock()
            guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else {
                fail(id, SteamUI.Failure.badReply); return
            }
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                if let error { self?.fail(id, error) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let pending = self.waiters[id] != nil; self.lock.unlock()
                guard pending else { return }
                if closeOnTimeout { self.close(SteamUI.Failure.timeout) } else { self.fail(id, SteamUI.Failure.timeout) }
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
        waiter?.resume(throwing: error)
    }

    func close(_ error: Error?) {
        lock.lock()
        let wasClosed = closed
        closed = true
        let pending = waiters
        waiters = [:]
        let handler = closeHandler
        lock.unlock()
        guard !wasClosed else { return }
        task.cancel(with: .normalClosure, reason: nil)
        for w in pending.values { w.resume(throwing: error ?? SteamUI.Failure.unreachable) }
        handler?()
    }
}
