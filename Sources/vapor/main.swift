import Foundation
import VaporKit

// vapor — headless front end to VaporKit.
//   vapor libraries                 list Steam installs and installed apps
//   vapor profile <appid>           full profile for one installed game
//   vapor scan                      one-line profile for every installed Windows game
//   vapor wine …                    engines, renderer packs, variants, prefix setup (WineCommand.swift)
// Options: --prefix <wine prefix>   add a Windows Steam inside that prefix (repeatable)

var args = Array(CommandLine.arguments.dropFirst())
var prefixes: [URL] = []
while let i = args.firstIndex(of: "--prefix"), i + 1 < args.count {
    prefixes.append(URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath))
    args.removeSubrange(i...i + 1)
}
// Heroic's default Steam prefix is picked up automatically when present.
let heroicPrefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Heroic/Prefixes/Steam")
if prefixes.isEmpty, FileManager.default.fileExists(atPath: heroicPrefix.path) { prefixes.append(heroicPrefix) }

let installs = ([SteamInstall.nativeDefault] + prefixes.map(SteamInstall.wine)).filter(\.exists)
let antiCheat = try? AntiCheatDB(contentsOf: AntiCheatDB.heroicCache)

struct Located { let install: SteamInstall; let app: InstalledApp }
func installedApps() -> [Located] {
    installs.flatMap { inst in inst.installedApps().map { Located(install: inst, app: $0) } }
}

var appInfoCache: [String: AppInfo] = [:]
func profiler(for install: SteamInstall) -> Profiler {
    let key = install.appInfoURL.path
    if appInfoCache[key] == nil { appInfoCache[key] = try? AppInfo(contentsOf: install.appInfoURL) }
    return Profiler(appInfo: appInfoCache[key], antiCheatDB: antiCheat)
}

func label(_ i: SteamInstall) -> String { i.kind == .native ? "native" : "wine:\(i.prefix!.lastPathComponent)" }

func printProfile(_ p: GameProfile, install: SteamInstall) {
    let a = p.analysis
    print("\(p.name) [\(p.appid)] — \(label(install))")
    print("  install     \(a.installDir.path)")
    print("  executable  \(a.mainExecutable?.lastPathComponent ?? "?") (\(a.mainMachine?.rawValue ?? "?")\(a.isDotNet ? ", .NET" : ""))")
    print("  store OS    \(p.metadata?.osList.joined(separator: ",") ?? "?")")
    print("  engine      \(a.engine.rawValue); modules scanned: \(a.scannedModules)")
    let apis = a.likelyAPIs.map { api -> String in
        let e = a.graphics[api]!
        return "\(api.rawValue)(\(e.strong.isEmpty ? "string" : "import"): \((e.strong + e.weak).prefix(2).joined(separator: ", ")))"
    }
    print("  graphics    \(apis.isEmpty ? "none detected" : apis.joined(separator: "; "))")
    print("  steamworks  \(a.usesSteamworks ? "yes" : "no")")
    if let plan = p.launch {
        print("  launch      \(plan.executable)\(plan.arguments.isEmpty ? "" : " " + plan.arguments.joined(separator: " "))\(plan.workingDirectory.map { "  (cwd \($0))" } ?? "")\(plan.bypassesAntiCheat ? "  [anti-cheat skipped, offline only]" : "")")
    }
    if !a.antiCheats.isEmpty { print("  anti-cheat  \(a.antiCheats.map { "\($0.name) (\($0.evidence))" }.joined(separator: ", "))") }
    if let ac = p.antiCheatStatus { print("  AWACY       \(ac.status) — \(ac.antiCheats.joined(separator: ","))") }
    if !a.thirdPartyLaunchers.isEmpty { print("  launchers   \(a.thirdPartyLaunchers.joined(separator: ", "))") }
    if p.valveFlags.isEmpty { print("  valve       no Proton quirks on record") }
    for q in p.quirks { print("  valve       \(q.flag): \(q.status.rawValue) — \(q.effect)") }
    print("  ladder")
    for (i, r) in p.ladder.enumerated() {
        print("    \(i + 1). \(r.renderer.rawValue)\(r.arguments.isEmpty ? "" : " " + r.arguments.joined(separator: " "))\(r.experimental ? " [experimental]" : "") — \(r.reason)")
    }
    print("  verdict     \(p.verdict.rawValue)\(p.verdictReasons.isEmpty ? "" : ": " + p.verdictReasons.joined(separator: "; "))")
}

switch args.first {
case "libraries":
    for inst in installs {
        print("\(label(inst))  \(inst.root.path)")
        for f in inst.libraryFolders() { print("  library \(f.path)") }
        for app in inst.installedApps() { print("  \(app.appid)\t\(app.isFullyInstalled ? "installed" : "flags=\(app.stateFlags)")\t\(app.name)") }
    }
case "profile":
    guard args.count > 1, let id = UInt32(args[1]) else { print("usage: vapor profile <appid>"); exit(2) }
    let hits = installedApps().filter { $0.app.appid == id }
    if hits.isEmpty { print("app \(id) is not installed in: \(installs.map(label).joined(separator: ", "))"); exit(1) }
    for h in hits { printProfile(profiler(for: h.install).profile(appid: id, installDir: h.app.installDir, fallbackName: h.app.name), install: h.install) }
case "scan":
    for h in installedApps() {
        let p = profiler(for: h.install).profile(appid: h.app.appid, installDir: h.app.installDir, fallbackName: h.app.name)
        guard p.metadata?.isWindowsOnly ?? true || h.install.kind == .wine else { continue }
        // Skip redistributables, SDKs and other non-game tools.
        if let type = p.metadata?.type.lowercased(), !["game", "application", "demo"].contains(type) { continue }
        let apis = p.analysis.likelyAPIs.map(\.rawValue).joined(separator: "+")
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
        print([pad(String(h.app.appid), 9), pad(p.name, 28), pad(p.analysis.mainMachine?.rawValue ?? "?", 6),
               pad(apis.isEmpty ? "-" : apis, 14), pad(p.ladder.first?.renderer.rawValue ?? "-", 15), p.verdict.rawValue].joined(separator: " "))
    }
case "engine":
    guard let ws = WindowsSteam.detectDefault() else { print("no Windows Steam prefix found"); exit(1) }
    func show() {
        let users = ws.install.users()
        print("prefix   \(ws.prefix.path)")
        print("running  \(ws.isRunning) pids=\(ws.clientProcesses())")
        print("state    \(ws.connection())")
        print("login    saved=\(ws.hasSavedLogin) users=\(users.map(\.accountID))")
        print("mac steam running: \(WindowsSteam.nativeSteamRunning)")
    }
    switch args.dropFirst().first {
    case "status", nil:
        show()
    case "start", "login":
        let silent = args[1] == "start"
        do {
            try ws.start(silent: silent, allowNativeConflict: args.contains("--force"))
            print("started (\(silent ? "headless" : "with login window")), waiting for logon…")
            print("state    \(ws.waitForLogon())")
        } catch { print("error: \(error)"); exit(1) }
    case "stop":
        ws.stop()
        show()
    case "library":
        let info = ws.appInfo()
        let installed = Set(ws.installedApps().map(\.appid))
        for id in ws.ownedAppIDs() {
            guard let raw = info?[id], let m = AppMetadata(appid: id, info: raw), m.type.lowercased() == "game" else { continue }
            print("\(id)\t\(installed.contains(id) ? "installed" : "-        ")\t\(m.osList.joined(separator: ","))\t\(m.name)")
        }
    case "progress":
        guard args.count > 2, let id = UInt32(args[2]) else { print("usage: vapor engine progress <appid>"); exit(2) }
        if let p = ws.progress(id) {
            print("flags=\(p.stateFlags) \(p.downloaded)/\(p.total) (\(Int(p.fraction * 100))%) installed=\(p.isInstalled) queued=\(p.isQueued) downloading=\(p.isDownloading)")
        } else { print("not installed or queued") }
    case "install":
        guard args.count > 2, let id = UInt32(args[2]) else { print("usage: vapor engine install <appid>"); exit(2) }
        do {
            try ws.queueInstall(id, accountSteamID64: ws.install.users().first?.steamID64)
            print("queued \(id); Steam downloads it in the background")
        } catch { print("error: \(error)"); exit(1) }
    case "run":
        // vapor engine run <appid> <install dir> <exe relative to dir> [args…]
        guard args.count > 4, let id = UInt32(args[2]) else { print("usage: vapor engine run <appid> <dir> <exe> [args]"); exit(2) }
        do {
            let variant = ProcessInfo.processInfo.environment["VAPOR_VARIANT"].map { URL(fileURLWithPath: $0) }
            let p = try ws.launch(appid: id, installDir: URL(fileURLWithPath: args[3]), executable: args[4],
                                  arguments: Array(args.dropFirst(5)), engineVariant: variant)
            p.waitUntilExit()
            print("exited \(p.terminationStatus); output in \(ws.logURL.path)")
        } catch { print("error: \(error)"); exit(1) }
    case "ui":
        // vapor engine ui snapshot|library|probe <appid>|install <appid>|uninstall <appid>|pause|resume <appid>|show|hide|session
        //                 |achievements <appid>|friends
        let ui = SteamUI(port: Int(ProcessInfo.processInfo.environment["VAPOR_CDP_PORT"] ?? "") ?? SteamUI.port)
        let sub = args.count > 2 ? args[2] : "snapshot"
        let id = args.count > 3 ? UInt32(args[3]) : nil
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                switch sub {
                case "snapshot", "library":
                    let s = try await ui.snapshot(includeApps: sub == "library")
                    print("logged in \(s.loggedIn)")
                    for f in s.folders { print("folder \(f.index) \(f.path) free \(f.free / 1_000_000_000) GB\(f.isDefault ? " (default)" : "")") }
                    if let a = s.account { print("account \(a.persona) wallet \(a.wallet.isEmpty ? "-" : a.wallet)") }
                    print("took over \(s.detached)")
                    if let running = s.running, !running.isEmpty { print("running \(running)") }
                    if let o = s.overview { print("active \(o.appid) \(o.state) \(Int(o.percent))% \(o.networkBytesPerSecond / 1000) kB/s\(o.paused ? " paused" : "")") }
                    for d in s.downloads { print("queue \(d.appid) pos=\(d.queueIndex) \(d.downloaded)/\(d.total)\(d.paused ? " paused" : "")\(d.completed ? " done" : "")") }
                    if let i = s.install { print("install \(i.appid) \(i.stateName) need=\(i.required) free=\(i.available) step=\(i.step ?? "-") problem=\(i.problem ?? "-") done=\(i.done)") }
                    if let sh = s.shelves { print("favorites \(sh.favorites) hidden \(sh.hidden) collections \(sh.collections.map { "\($0.name)(\($0.apps.count))" })") }
                    for a in s.apps ?? [] where a.type == 1 { print("\(a.appid)\t\(a.installed ? "installed" : "-        ")\t\(a.name)") }
                case "probe":
                    guard let id else { print("usage: vapor engine ui probe <appid>"); return }
                    if let i = try await ui.probeInstall(id) {
                        print("\(i.appid) \(i.stateName) need \(i.required) bytes, free \(i.available), needsUser \(i.needsUser)")
                    } else { print("no answer from the install wizard") }
                case "install": guard let id else { return }; try await ui.install(id); print("install requested")
                case "uninstall": guard let id else { return }; try await ui.uninstall(id); print("uninstall requested")
                case "pause": guard let id else { return }; try await ui.pause(id)
                case "resume": guard let id else { return }; try await ui.resume(id)
                case "watch":
                    // Prints pushed snapshots for 12 s (latency check).
                    let start = Date()
                    ui.subscribe { s in
                        print(String(format: "%6.2fs", Date().timeIntervalSince(start)), "push: downloads=\(s.downloads.count) apps=\(s.apps?.count ?? -1) active=\(s.overview.map { "\($0.appid) \($0.state)" } ?? "-")")
                    }
                    let ok = await ui.connect()
                    print(String(format: "%6.2fs", Date().timeIntervalSince(start)), "connected \(ok)")
                    let t0 = Date(); _ = try await ui.snapshot()
                    print("call round trip \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    try await Task.sleep(nanoseconds: 12_000_000_000)
                case "details":
                    guard let id, let d = try await ui.details(id) else { print("no details"); return }
                    print("\(d.name) installed=\(d.installed) size=\(d.diskUsage) build=\(d.buildID) folder=\(d.installFolder)")
                    print("launch='\(d.launchOptions)' lang=\(d.selectedLanguage) of \(d.languages.count) cloud=\(d.cloudEnabled) \(d.cloudUsed) autoupdate=\(d.autoUpdate) bg=\(d.backgroundDownloads)")
                    print("betas \(d.betas.map(\.name)) selected=\(d.selectedBeta) dlc=\(d.dlc.count)")
                case "settings":
                    let st = try await ui.settings()
                    print("region \(st.downloadRegion) (\(st.regions.first { $0.id == st.downloadRegion }?.name ?? "?")) of \(st.regions.count); throttle \(st.throttleKbps); lang \(st.language) of \(st.languages.count); folders \(st.folders.map(\.path))")
                case "achievements":
                    guard let id else { print("usage: vapor engine ui achievements <appid>"); return }
                    let list = try await ui.achievements(id)
                    print("\(list.filter(\.achieved).count)/\(list.count) unlocked")
                    for a in list {
                        print("\(a.achieved ? "unlocked" : "-       ") \(String(format: "%5.1f%%", a.globalPercent)) \(a.id)\t\(a.name)\(a.hidden ? " (hidden)" : "")")
                    }
                case "friends":
                    for f in try await ui.friends().sorted(by: { ($0.isOnline ? 0 : 1, $0.name) < ($1.isOnline ? 0 : 1, $1.name) }) {
                        let game = f.gameAppID == 0 ? "" : " playing \(f.gameName.isEmpty ? String(f.gameAppID) : f.gameName) [\(f.gameAppID)]"
                        print("\(f.steamID)\tstate=\(f.state)\t\(f.name)\(game)")
                    }
                case "accept-eulas": try await ui.acceptEulas()
                case "cancel": try await ui.cancelInstall()
                case "show", "hide": try await ui.showSteamWindow(sub == "show")
                case "session":
                    // Counts only; values never printed.
                    let cookies = try await ui.webCookies()
                    print("\(cookies.count) cookies, login cookie on \(Set(cookies.filter { $0.name == "steamLoginSecure" }.map(\.domain)).sorted())")
                    print("UA \(try await ui.storeUserAgent())")
                default: print("unknown ui command \(sub)")
                }
            } catch { print("error: \(error)") }
        }
        done.wait()
    default:
        print("usage: vapor engine status|start|login|stop|library|progress <appid>|install <appid>|run …|ui …")
    }
case "wine":
    wineCommand(Array(args.dropFirst()))
default:
    print("usage: vapor libraries | profile <appid> | scan | engine … | wine …   [--prefix <wine prefix>]")
}
