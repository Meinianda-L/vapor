import Foundation

/// Steam Cloud around a game Vapor starts itself, and launches handed to Steam.
///
/// Steam syncs a game's cloud files inside its own launch (LaunchApp's SynchronizingCloud step) and when the game
/// exits. A game Vapor runs on its renderer's engine skips that launch, so Vapor drives the same sync through what
/// Steam's library page uses for its 云状态 row: the app's `eCloudStatus`, `Cloud.RetryAppSync` (a full sync) and
/// `Cloud.ResolveAppSyncConflict`. steamui has no other call that starts a sync.
extension SteamUI {
    /// steamui's EAppCloudStatus (AppDetails.eCloudStatus).
    public enum CloudStatus: Int, Sendable {
        case invalid = 0, disabled, unknown, synchronized, checking, outOfSync, uploading, downloading, syncFailed, conflict, pendingElsewhere

        /// Steam's label for it: AppDetails_CloudStatus_<key>.
        public var stringKey: String {
            switch self {
            case .invalid, .unknown: return "Unknown"
            case .disabled: return "Disabled"
            case .synchronized: return "Synchronized"
            case .checking: return "Checking"
            case .outOfSync: return "OutOfSync"
            case .uploading: return "Uploading"
            case .downloading: return "Downloading"
            case .syncFailed: return "SyncFailed"
            case .conflict: return "Conflict"
            case .pendingElsewhere: return "PendingElsewhere"
            }
        }

        public var isTransferring: Bool { self == .checking || self == .uploading || self == .downloading }
    }

    public struct CloudState: Decodable, Sendable, Equatable {
        public let status: Int
        public let available: Bool
        /// On for both the account and the app.
        public let enabled: Bool
        public let percent: Int

        public init(status: CloudStatus, available: Bool = true, enabled: Bool = true, percent: Int = 0) {
            self.status = status.rawValue
            self.available = available
            self.enabled = enabled
            self.percent = percent
        }

        public var cloudStatus: CloudStatus { CloudStatus(rawValue: status) ?? .unknown }
        public var inUse: Bool { available && enabled && cloudStatus != .disabled && cloudStatus != .invalid }
    }

    /// The app's cloud state (nil when Steam does not answer within 6 s). With `changedFrom`, waits up to `within`
    /// seconds for Steam to report something else and returns the latest state either way (one registration, so
    /// polling a transfer does not re-request the app's details every second).
    public func cloudState(_ appid: UInt32, changedFrom old: CloudState? = nil, within seconds: Double = 0) async throws -> CloudState? {
        let old = old.map { "\($0.status),\($0.percent)" } ?? ""
        let data = try await evaluate("""
            const read = d => d && { status: d.eCloudStatus ?? 0, available: !!d.bCloudAvailable,
                                     enabled: !!d.bCloudEnabledForApp && !!d.bCloudEnabledForAccount, percent: d.nCloudProgressPercent ?? 0 };
            return await new Promise(resolve => {
              let h = null, last = null, done = false;
              const finish = () => { if (done) return; done = true; setTimeout(() => h?.unregister?.(), 0); resolve(last); };
              h = SteamClient.Apps.RegisterForAppDetails(\(appid), d => {
                last = read(d) ?? last;
                if (last && (\(old.isEmpty ? "true" : "false") || `${last.status},${last.percent}` !== '\(old)')) finish();
              });
              setTimeout(finish, \(old.isEmpty ? 6000 : Int(max(seconds, 0.5) * 1000)));
            });
            """)
        return try JSONDecoder().decode(CloudState?.self, from: data)
    }

    /// Steam's 重试同步: a full sync of the app's cloud files, both ways.
    public func retryCloudSync(_ appid: UInt32) async throws {
        _ = try await evaluate("await SteamClient.Cloud.RetryAppSync(\(appid)); return true;")
    }

    public func resolveCloudConflict(_ appid: UInt32, keepLocal: Bool) async throws {
        _ = try await evaluate("await SteamClient.Cloud.ResolveAppSyncConflict(\(appid), \(keepLocal)); return true;")
    }

    /// Newest local and cloud file times of a conflict (Unix seconds), for the conflict dialog.
    public func cloudConflictTimes(_ appid: UInt32) async throws -> (local: Int, remote: Int) {
        let data = try await evaluate("const t = await SteamClient.Apps.GetConflictingFileTimestamps(\(appid)); return [t?.rtLocalTime ?? 0, t?.rtRemoteTime ?? 0];")
        let t = try JSONDecoder().decode([Int].self, from: data)
        return (t.first ?? 0, t.last ?? 0)
    }

    /// Apps Steam considers running: started by Steam, or a game that signed in to Steamworks.
    public func runningApps() async throws -> [UInt32] {
        try JSONDecoder().decode([UInt32].self, from: try await evaluate("return (SteamUIStore.RunningApps || []).map(a => a.appid);"))
    }

    /// Steam's own 开始游戏 (library details launch source): cloud sync, install scripts, EULAs, playtime and the exit
    /// sync all happen in Steam. Its questions and progress reach Vapor through the agent's dialogs and launches.
    public func runGame(_ appid: UInt32) async throws {
        _ = try await evaluate("""
            const o = appStore.GetAppOverviewByAppID(\(appid));
            if (!o) throw new Error('Steam 不认识 \(appid)');
            SteamClient.Apps.RunGame(o.GetGameID(), '', -1, 100);
            try { SteamUIStore.SetRunningApp(\(appid)); } catch {}
            return true;
            """)
    }

    /// Steam's 停止 for a game Steam started.
    public func terminateGame(_ appid: UInt32) async throws {
        _ = try await evaluate("""
            const o = appStore.GetAppOverviewByAppID(\(appid));
            if (o) SteamClient.Apps.TerminateApp(o.GetGameID(), false);
            return true;
            """)
    }

    /// Runs one cloud sync around a launch and waits for it, reporting each state Steam passes through.
    /// Gives up after `timeout`; never throws, since a launch should not depend on Steam answering.
    public func syncCloud(_ appid: UInt32, phase: CloudSyncPlan.Phase, timeout: TimeInterval,
                          progress: @escaping @Sendable (CloudState) -> Void) async -> CloudSyncPlan.Result {
        var plan = CloudSyncPlan(phase: phase)
        let deadline = Date().addingTimeInterval(timeout)
        var state = try? await cloudState(appid)
        while true {
            if let state { progress(state) }
            switch plan.next(state) {
            case let .done(result): return result
            case .sync: try? await retryCloudSync(appid)
            case .wait: break
            }
            if Date() > deadline { return .timedOut }
            guard let current = state else { return .notUsed }
            state = (try? await cloudState(appid, changedFrom: current, within: 3)) ?? current
        }
    }
}

/// The decisions of one cloud sync around a launch, kept apart from Steam so they can be tested.
public struct CloudSyncPlan: Sendable {
    public enum Phase: Sendable { case beforeLaunch, afterExit }
    public enum Result: Sendable, Equatable { case notUsed, synchronized, conflict, failed, pendingElsewhere, timedOut }
    public enum Step: Sendable, Equatable { case done(Result), sync, wait }

    /// Polls without a change after asking for a sync before Steam's unchanged status is believed: Steam may take a
    /// moment to leave "synchronized" for "checking".
    static let settlePolls = 3

    public let phase: Phase
    public private(set) var requested = false
    private var sawTransfer = false
    private var quiet = 0

    public init(phase: Phase) { self.phase = phase }

    public mutating func next(_ state: SteamUI.CloudState?) -> Step {
        guard let state, state.inUse else { return .done(.notUsed) }
        let status = state.cloudStatus
        if status.isTransferring {
            sawTransfer = true
            quiet = 0
            return .wait
        }
        if status == .conflict { return .done(.conflict) }
        if requested && !sawTransfer && quiet < Self.settlePolls {
            quiet += 1
            return .wait
        }
        switch status {
        case .outOfSync, .syncFailed:
            return requested ? .done(.failed) : request()
        case .pendingElsewhere:
            return phase == .afterExit && !requested ? request() : .done(.pendingElsewhere)
        default:
            // Before a launch an up-to-date status is trusted; after the game exits only Steam can tell what changed.
            return phase == .afterExit && !requested ? request() : .done(.synchronized)
        }
    }

    private mutating func request() -> Step {
        requested = true
        sawTransfer = false
        return .sync
    }
}

extension SteamUI.Dialog {
    /// A question Vapor asks itself, shown the same way as Steam's own (see SteamDialogs).
    public init(vapor kind: String, appid: UInt32, title: Text, message: [Text], note: Text? = nil, buttons: [Choice],
                localTime: Int = 0, remoteTime: Int = 0) {
        self.init(id: "vapor-\(kind)-\(appid)-\(UUID().uuidString)", kind: kind, appid: appid, title: title, message: message,
                  note: note, buttons: buttons, eulas: nil, keys: nil, code: 0, details: nil, localTime: localTime, remoteTime: remoteTime, remember: nil)
    }
}

extension SteamUI.Dialog.Text {
    /// Steam's string `key` (shown in Chinese by SteamDialogs), with `fallback` when the table lacks it or there is no key.
    public init(key: String?, _ fallback: String, _ args: String...) {
        self.init(text: fallback, key: key, args: args)
    }
}

extension SteamUI.Dialog.Choice {
    public init(_ id: String, _ label: SteamUI.Dialog.Text, role: String? = nil) {
        self.init(id: id, label: label, role: role)
    }
}
