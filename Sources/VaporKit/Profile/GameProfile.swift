import Foundation

/// Everything Vapor knows about one game before its first launch.
public struct GameProfile: Sendable {
    public enum Verdict: String, Sendable {
        case expected           // nothing known to block it
        case needsTesting       // user-mode anti-cheat with no runtime under macOS Wine, or otherwise unproven
        case needsLauncher      // depends on a third-party launcher (Ubisoft, EA, ...)
        case blocked            // kernel anti-cheat, or denied by the developer with no way around it
    }

    public let appid: UInt32
    public let name: String
    public let metadata: AppMetadata?
    public let analysis: GameAnalysis
    public let valveFlags: [String]
    public let quirks: [QuirkResolution]
    public let settings: WineSettings
    public let antiCheatStatus: AntiCheatDB.Entry?
    /// What the default launch runs (nil when its executable is missing).
    public let launch: LaunchPlan?
    public let ladder: [LadderRung]
    public let verdict: Verdict
    public let verdictReasons: [String]

    /// The launch skips the game's anti-cheat, so online play will not work.
    public var offlineOnly: Bool { launch?.bypassesAntiCheat ?? false }

    /// What to run for a ladder rung: its own launch entry, or the default one.
    public func plan(for rung: LadderRung?) -> LaunchPlan? { rung?.launch ?? launch }
}

/// One way to start the game. Paths are relative to `GameAnalysis.installDir`, with forward slashes.
public struct LaunchPlan: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// nil runs the game from its executable's folder.
    public let workingDirectory: String?
    /// The launch entry is an anti-cheat bootstrap; Vapor runs the game executable behind it.
    public let bypassesAntiCheat: Bool

    public func executableURL(in installDir: URL) -> URL { installDir.appendingPathComponent(executable) }

    /// The working directory, falling back to the executable's folder when unset or missing.
    public func workingDirectoryURL(in installDir: URL) -> URL {
        var isDir: ObjCBool = false
        if let workingDirectory {
            let url = installDir.appendingPathComponent(workingDirectory)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return executableURL(in: installDir).deletingLastPathComponent()
    }

    /// The plan for a Steam launch entry. EasyAntiCheat and BattlEye have no runtime under
    /// macOS Wine, so their bootstrap can only fail; the game executable it would start
    /// usually runs offline, so that is what Vapor launches instead.
    public static func resolving(_ entry: AppMetadata.LaunchEntry, in installDir: URL) -> LaunchPlan {
        let workingDir = AppMetadata.normalizeExecutable(entry.workingDir)
        return resolving(executable: entry.executable, arguments: entry.parsedArguments,
                         workingDirectory: workingDir.isEmpty ? nil : workingDir, in: installDir)
    }

    static func resolving(executable: String, arguments: [String] = [], workingDirectory: String? = nil,
                          in installDir: URL) -> LaunchPlan {
        let normalized = AppMetadata.normalizeExecutable(executable)
        let exe = locate(normalized, in: installDir) ?? normalized
        let game = antiCheatTarget(of: exe, in: installDir)
        return LaunchPlan(executable: game ?? exe, arguments: arguments, workingDirectory: workingDirectory,
                          bypassesAntiCheat: game != nil)
    }

    /// The game executable an anti-cheat bootstrap starts, relative to the install dir.
    static func antiCheatTarget(of exe: String, in installDir: URL) -> String? {
        let dir = (exe as NSString).deletingLastPathComponent
        let name = (exe as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension.lowercased()
        func existing(_ candidates: [String]) -> String? {
            for c in candidates where c.caseInsensitiveCompare(name) != .orderedSame {
                let rel = dir.isEmpty ? c : dir + "/" + c
                if let found = locate(rel, in: installDir) { return found }
            }
            return nil
        }

        func sibling(_ file: String) -> String? { locate(dir.isEmpty ? file : dir + "/" + file, in: installDir) }

        // EasyAntiCheat: start_protected_game.exe (or a renamed copy) reads the game's name from Settings.json.
        // Only the bootstrap is redirected; another exe that merely sits beside the EasyAntiCheat folder
        // (a singleplayer build, a launcher) is a launch of its own.
        if isEasyAntiCheatBootstrap(exe, in: installDir),
           let settings = sibling("EasyAntiCheat/Settings.json"),
           var data = try? Data(contentsOf: installDir.appendingPathComponent(settings)) {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data(data.dropFirst(3)) }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let target = json["executable"] as? String, !target.isEmpty {
                return existing([AppMetadata.normalizeExecutable(target)])
            }
        }

        // BattlEye: <Game>_BE.exe / <Game>BattlEye.exe start the game named in BELauncher.ini.
        let stem = base.hasSuffix("_be") ? base.dropLast(3) : base.hasSuffix("battleye") ? base.dropLast(8) : ""
        guard !stem.isEmpty else { return nil }
        var named: [String] = []
        for ini in ["BELauncher.ini", "BattlEye/BELauncher.ini"] {
            guard let rel = sibling(ini),
                  let text = try? String(contentsOf: installDir.appendingPathComponent(rel), encoding: .utf8) else { continue }
            for key in ["64bitexe", "32bitexe"] {
                for line in text.split(whereSeparator: \.isNewline) {
                    let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2, kv[0].lowercased() == key, !kv[1].isEmpty { named.append(AppMetadata.normalizeExecutable(kv[1])) }
                }
            }
        }
        guard !named.isEmpty || sibling("BattlEye") != nil else { return nil }
        let game = stem.hasSuffix("_") ? stem.dropLast() : stem
        return existing(named + ["\(game)_x64.exe", "\(game)64.exe", "\(game).exe"])
    }

    /// start_protected_game.exe, a copy named like EAC, or a small stub that imports no graphics API.
    static func isEasyAntiCheatBootstrap(_ exe: String, in installDir: URL) -> Bool {
        let base = ((exe as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if base == "start_protected_game" || base.contains("easyanticheat") || base.contains("protected")
            || base.hasPrefix("eac") || base.hasSuffix("_eac") { return true }
        let url = installDir.appendingPathComponent(exe)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8 << 20,
              let pe = try? PEFile(url: url) else { return false }
        return pe.imports.isDisjoint(with: GraphicsAPI.allCases.flatMap(\.modules))
    }

    /// `relative` under `installDir`, matching each component case-insensitively as Windows
    /// does; returns the on-disk spelling, or nil when missing or outside the install dir.
    static func locate(_ relative: String, in installDir: URL) -> String? {
        let fm = FileManager.default
        var parts: [String] = []
        for part in relative.split(separator: "/") where part != "." {
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
                continue
            }
            let parent = parts.reduce(installDir) { $0.appendingPathComponent($1) }
            guard let match = (try? fm.contentsOfDirectory(atPath: parent.path))?
                .first(where: { $0.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            parts.append(match)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

public struct Profiler: Sendable {
    public let appInfo: AppInfo?
    public let valve: ValveCompatManifest?
    public let antiCheatDB: AntiCheatDB?
    public let engine: EngineCapabilities

    public init(appInfo: AppInfo?, antiCheatDB: AntiCheatDB?, engine: EngineCapabilities = .crossOverBased) {
        self.appInfo = appInfo
        self.valve = appInfo.map(ValveCompatManifest.init)
        self.antiCheatDB = antiCheatDB
        self.engine = engine
    }

    public func profile(appid: UInt32, installDir: URL, fallbackName: String = "") -> GameProfile {
        let meta = appInfo?[appid].flatMap { AppMetadata(appid: appid, info: $0) }
        let entry = meta?.windowsLaunch
        let requested = entry.map { LaunchPlan.resolving($0, in: installDir) }
            ?? guessExecutable(in: installDir).map { LaunchPlan.resolving(executable: $0, in: installDir) }
        let analysis = GameAnalyzer.analyze(installDir: installDir, executable: requested?.executable)
        let launch = requested.flatMap { plan in
            analysis.mainExecutableRelative.map {
                LaunchPlan(executable: $0, arguments: plan.arguments, workingDirectory: plan.workingDirectory,
                           bypassesAntiCheat: plan.bypassesAntiCheat)
            }
        }
        let flags = valve?.configs[appid] ?? []
        let (settings, quirks) = QuirkTranslator.translate(flags, engine: engine)
        let ac = antiCheatDB?[appid]
        let skip = Set([entry?.executable, requested?.executable, launch?.executable].compactMap { $0?.lowercased() })
        let alternates = (meta?.windowsLaunchEntries ?? []).filter { $0 != entry }
            .map { LaunchPlan.resolving($0, in: installDir) }
            .filter { !skip.contains($0.executable.lowercased()) }
        let ladder = RendererLadder.build(for: analysis, settings: settings, alternates: alternates)

        var reasons: [String] = []
        var verdict = GameProfile.Verdict.expected
        func raise(_ v: GameProfile.Verdict, _ why: String) {
            reasons.append(why)
            let rank: [GameProfile.Verdict] = [.expected, .needsTesting, .needsLauncher, .blocked]
            if rank.firstIndex(of: v)! > rank.firstIndex(of: verdict)! { verdict = v }
        }
        let kernel = unique(analysis.antiCheats.filter(\.kernelLevel).map(\.name) + (ac?.kernelLevelAntiCheats ?? []))
        for name in kernel { raise(.blocked, String(localized: "\(name) 是内核级反作弊，无法在 Wine 中运行")) }
        // AreWeAntiCheatYet describes Linux/Proton, which ships EAC and BattlEye runtimes; macOS Wine
        // has neither, so whatever the status, online anti-cheat will not work here. Only a developer's
        // denial blocks the game, and only when there is no bootstrap to skip.
        let userMode = unique(analysis.antiCheats.filter { !$0.kernelLevel }.map(\.name)
                              + (ac?.antiCheats ?? []).filter { $0 != "VAC" })
            .filter { n in !kernel.contains { Self.sameAntiCheat($0, n) } }
        let source = ac.map { ac -> String in
            let parts = [ac.status, String(ac.dateChanged.prefix(10))]
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return "（AreWeAntiCheatYet" + (parts.isEmpty ? "" : "：" + parts.joined(separator: "，")) + "）"
        } ?? ""
        let offline = launch?.bypassesAntiCheat ?? false
        if let ac, ac.status == "Denied", kernel.isEmpty {
            let denied = unique(ac.antiCheats.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            let what = denied.isEmpty ? String(localized: "反作弊") : denied.joined(separator: "/")
            raise(offline ? .needsTesting : .blocked, String(localized: "开发者不允许 \(what) 在 Wine/Proton 下运行\(source)"))
        } else if !userMode.isEmpty {
            raise(.needsTesting, String(localized: "macOS Wine 没有 \(userMode.joined(separator: ")/String(localized: ")) 的运行环境，无法联机\(source)"))
        }
        if let launch, offline {
            raise(.needsTesting, String(localized: "仅限离线：跳过反作弊，直接启动 \((launch.executable as NSString).lastPathComponent)"))
        }
        for l in analysis.thirdPartyLaunchers { raise(.needsLauncher, String(localized: "需要 \(l)")) }

        return GameProfile(appid: appid,
                           name: meta?.name ?? fallbackName,
                           metadata: meta,
                           analysis: analysis,
                           valveFlags: flags,
                           quirks: quirks,
                           settings: settings,
                           antiCheatStatus: ac,
                           launch: launch,
                           ladder: ladder,
                           verdict: verdict,
                           verdictReasons: reasons)
    }

    /// Names for one product, keeping the first spelling: fingerprints and AreWeAntiCheatYet
    /// spell them differently ("EA Javelin" / "Javelin", "Easy Anti-Cheat (EOS)").
    private func unique(_ names: [String]) -> [String] {
        var kept: [String] = []
        for n in names where !kept.contains(where: { Self.sameAntiCheat($0, n) }) { kept.append(n) }
        return kept
    }

    static func sameAntiCheat(_ a: String, _ b: String) -> Bool {
        let ka = antiCheatKey(a), kb = antiCheatKey(b)
        guard ka.count >= 4, kb.count >= 4 else { return ka == kb }   // "ac", "eac" must match exactly
        return ka.contains(kb) || kb.contains(ka)
    }

    /// Lower-cased, without a trailing "(...)" and anything but letters and digits.
    static func antiCheatKey(_ name: String) -> String {
        var s = name.lowercased()
        if s.hasSuffix(")"), let open = s.lastIndex(of: "(") { s = String(s[..<open]) }
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Without appinfo, pick the largest top-level .exe that is not an installer or crash reporter.
    func guessExecutable(in dir: URL) -> String? {
        let fm = FileManager.default
        let exes = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "exe" }
            .filter { n in !["unins", "setup", "crash", "report", "launcher", "redist"].contains { n.lastPathComponent.lowercased().contains($0) } }
        return exes.max { a, b in
            ((try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }?.lastPathComponent
    }
}
