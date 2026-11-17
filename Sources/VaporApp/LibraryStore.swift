import Foundation
import SwiftUI
import VaporKit

/// One entry in the library grid.
struct GameItem: Identifiable, Hashable {
    let appid: UInt32
    let name: String
    let installed: Bool
    let installKind: SteamInstall.Kind?
    let installDir: URL?
    let windowsOnly: Bool
    let hasMacBuild: Bool
    let profile: GameProfile?

    var id: UInt32 { appid }
    // SwiftUI skips redrawing views whose inputs compare equal, so this covers every field the
    // tile, detail page and properties sheet display.
    static func == (a: GameItem, b: GameItem) -> Bool {
        a.appid == b.appid && a.name == b.name && a.installed == b.installed && a.installKind == b.installKind
            && a.installDir == b.installDir && a.windowsOnly == b.windowsOnly && a.hasMacBuild == b.hasMacBuild
            && Self.sameDisplay(a.profile, b.profile)
    }
    private static func sameDisplay(_ a: GameProfile?, _ b: GameProfile?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let x = a.analysis, y = b.analysis
        return a.name == b.name && a.verdict == b.verdict && a.verdictReasons == b.verdictReasons
            && a.ladder == b.ladder && a.settings == b.settings && a.valveFlags == b.valveFlags
            && x.mainExecutable == y.mainExecutable && x.mainMachine == y.mainMachine && x.engine == y.engine
            && x.likelyAPIs == y.likelyAPIs && x.antiCheats == y.antiCheats && x.usesSteamworks == y.usesSteamworks
            && x.thirdPartyLaunchers == y.thirdPartyLaunchers
    }
    func hash(into h: inout Hasher) { h.combine(appid) }

    var verdict: GameProfile.Verdict? { profile?.verdict }
    var firstRenderer: Renderer? { profile?.ladder.first?.renderer }
    var archLabel: String? {
        switch profile?.analysis.mainMachine {
        case .i386: return String(localized: "32 位")
        case .amd64: return String(localized: "64 位")
        case .arm64: return "ARM64"
        default: return nil
        }
    }
}

/// Paths Vapor reads; defaults match this machine's layout and can be changed in Settings.
enum VaporPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var prefixes: [URL] {
        let heroic = home.appendingPathComponent("Games/Heroic/Prefixes/Steam")
        return FileManager.default.fileExists(atPath: heroic.path) ? [heroic] : []
    }
    static var engines: URL { home.appendingPathComponent("Applications/RE/engines") }
    static var benchResults: URL {
        if let custom = UserDefaults.standard.string(forKey: "benchResults") { return URL(fileURLWithPath: custom) }
        return home.appendingPathComponent("Documents/S-archive/bench/results")
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var games: [GameItem] = []
    @Published var loading = false
    @Published var installs: [SteamInstall] = []
    @Published var lastError: String?

    /// Owned apps as Steam's library reports them; re-applied on every scan.
    private var steamApps: [SteamUI.App] = []
    private let profiles = ProfileCache()
    private var scanning = false
    private var rescanPending = false

    /// Rescans the disk. Calls made while a scan runs collapse into one more scan after it, so results
    /// are applied in order.
    func load() async {
        guard !scanning else { rescanPending = true; return }
        scanning = true
        loading = true
        defer { scanning = false; loading = false }
        repeat {
            rescanPending = false
            let remote = steamApps, profiles = profiles
            let result = await Task.detached(priority: .userInitiated) { Self.scan(remote: remote, profiles: profiles) }.value
            installs = result.installs
            games = result.games
        } while rescanPending
    }

    /// Adds owned games Steam's library knows about but the file scan cannot see (no cached art yet).
    func merge(steamApps: [SteamUI.App]) {
        self.steamApps = steamApps
        let known = Set(games.map(\.appid))
        if steamApps.contains(where: { $0.type == 1 && !known.contains($0.appid) }) { Task { await load() } }
    }

    nonisolated static func scan(remote: [SteamUI.App] = [], profiles: ProfileCache = ProfileCache())
        -> (installs: [SteamInstall], games: [GameItem]) {
        let installs = ([SteamInstall.nativeDefault] + VaporPaths.prefixes.map(SteamInstall.wine)).filter(\.exists)
        let antiCheat = try? AntiCheatDB(contentsOf: AntiCheatDB.heroicCache)
        var items: [UInt32: GameItem] = [:]
        var appInfos: [String: AppInfo] = [:]

        for install in installs {
            let info = appInfos[install.appInfoURL.path] ?? (try? AppInfo(contentsOf: install.appInfoURL))
            appInfos[install.appInfoURL.path] = info
            let profiler = Profiler(appInfo: info, antiCheatDB: antiCheat)
            for app in install.installedApps() {
                let meta = info?[app.appid].flatMap { AppMetadata(appid: app.appid, info: $0) }
                if let type = meta?.type.lowercased(), !["game", "application", "demo"].contains(type) { continue }
                // Wine installs have engine.progress to explain a pending update; a native one with an
                // update queued is still launchable from Mac Steam, so only bit 4 counts there.
                let complete = install.kind == .wine ? app.isPlayable : app.isFullyInstalled
                // Only Windows builds need Vapor; native Mac installs are shown but not profiled.
                let needsVapor = install.kind == .wine || (meta?.isWindowsOnly ?? false)
                let profile = needsVapor && complete
                    ? profiles.profile(for: app) { profiler.profile(appid: app.appid, installDir: app.installDir, fallbackName: app.name) }
                    : nil
                let item = GameItem(appid: app.appid, name: meta?.name ?? app.name, installed: complete,
                                    installKind: install.kind, installDir: app.installDir,
                                    windowsOnly: meta?.isWindowsOnly ?? (install.kind == .wine),
                                    hasMacBuild: meta?.hasMacBuild ?? false, profile: profile)
                // Prefer the Windows install when a game exists in both, unless only the other one is complete.
                if items[app.appid]?.installed != true || (install.kind == .wine && complete) { items[app.appid] = item }
            }
        }

        // Owned but not installed. The library art cache is not a list of what the account owns (Steam
        // also caches art for wishlist items and store pages that were browsed), so ownership comes from
        // Steam's own library, remembered on disk for when the client is not running.
        let owned = OwnedApps.resolve(remote: remote)
        for source in installs {
            guard let info = appInfos[source.appInfoURL.path] else { continue }
            let cache = source.root.appendingPathComponent("appcache/librarycache")
            let ids = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).compactMap(UInt32.init)
            for id in ids where items[id] == nil && owned.contains(id) {
                guard let raw = info[id], let meta = AppMetadata(appid: id, info: raw),
                      meta.type.lowercased() == "game" else { continue }
                items[id] = GameItem(appid: id, name: meta.name, installed: false, installKind: nil, installDir: nil,
                                     windowsOnly: meta.isWindowsOnly, hasMacBuild: meta.hasMacBuild, profile: nil)
            }
        }

        // Owned games Steam reported that neither scan found. Without appinfo the platform is unknown;
        // they are listed under Windows games (the sidebar has no unknown bucket) and offered for
        // install through Windows Steam, since no Mac build is known.
        for app in remote where app.type == 1 && items[app.appid] == nil {
            let meta = appInfos.values.lazy.compactMap { $0[app.appid].flatMap { AppMetadata(appid: app.appid, info: $0) } }.first
            items[app.appid] = GameItem(appid: app.appid, name: meta?.name ?? app.name, installed: false, installKind: nil,
                                        installDir: nil, windowsOnly: meta?.isWindowsOnly ?? true,
                                        hasMacBuild: meta?.hasMacBuild ?? false, profile: nil)
        }

        let games = items.values.sorted { a, b in
            if a.installed != b.installed { return a.installed }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return (installs, games)
    }
}

/// The games the account owns, as the Windows Steam client lists them; the last answer is kept in
/// Application Support so the library is right while the client is stopped.
enum OwnedApps {
    private static var file: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vapor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owned-apps.json")
    }

    static func resolve(remote: [SteamUI.App]) -> Set<UInt32> {
        let live = Set(remote.filter { $0.type == 1 }.map(\.appid))
        if !live.isEmpty {
            if let data = try? JSONEncoder().encode(live.sorted()) { try? data.write(to: file, options: .atomic) }
            return live
        }
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([UInt32].self, from: data) else { return [] }
        return Set(ids)
    }
}

private extension InstalledApp {
    /// Fully installed with no update queued or downloading (Steam keeps bit 4 set while updating).
    var isPlayable: Bool { isFullyInstalled && stateFlags & (2 | 1024 | 1_048_576) == 0 }
}

/// Profiles of installed games, reused while the appmanifest is unchanged: PE analysis reads every
/// executable, and rescans happen whenever a download starts or finishes.
final class ProfileCache: @unchecked Sendable {
    private struct Entry { let modified: Date; let installDir: URL; let profile: GameProfile }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func profile(for app: InstalledApp, make: () -> GameProfile) -> GameProfile {
        let modified = (try? app.manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let key = app.manifest.path
        if let e = lock.withLock({ entries[key] }), e.modified == modified, e.installDir == app.installDir { return e.profile }
        let profile = make()
        lock.withLock { entries[key] = Entry(modified: modified, installDir: app.installDir, profile: profile) }
        return profile
    }
}

/// Loads artwork off the main thread: local Steam cache first, then a disk cache of CDN downloads.
@MainActor
final class ArtworkLoader: ObservableObject {
    static let shared = ArtworkLoader()
    private var memory: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    @Published private(set) var revision = 0

    nonisolated private static var diskCache: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Vapor/art")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func image(appid: UInt32, kind: Artwork.Kind, installs: [SteamInstall]) -> NSImage? {
        let key = "\(appid)-\(kind)"
        if let img = memory[key] { return img }
        if !inflight.contains(key) {
            inflight.insert(key)
            Task.detached(priority: .utility) {
                let img = Self.fetch(appid: appid, kind: kind, installs: installs)
                await MainActor.run {
                    if let img { self.memory[key] = img; self.revision += 1 }
                }
            }
        }
        return nil
    }

    /// Synchronous variant for snapshot rendering.
    func imageNow(appid: UInt32, kind: Artwork.Kind, installs: [SteamInstall]) -> NSImage? {
        let key = "\(appid)-\(kind)"
        if let img = memory[key] { return img }
        let img = Self.fetch(appid: appid, kind: kind, installs: installs)
        memory[key] = img
        return img
    }

    nonisolated static func fetch(appid: UInt32, kind: Artwork.Kind, installs: [SteamInstall]) -> NSImage? {
        if let local = Artwork.local(appid: appid, kind: kind, installs: installs) { return NSImage(contentsOf: local) }
        let cached = diskCache.appendingPathComponent("\(appid)-\(kind).img")
        if let img = NSImage(contentsOf: cached) { return img }
        guard let data = try? Data(contentsOf: Artwork.remote(appid: appid, kind: kind)), let img = NSImage(data: data) else { return nil }
        try? data.write(to: cached)
        return img
    }
}
