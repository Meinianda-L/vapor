import Foundation

/// Store metadata for one app, decoded from appinfo.
public struct AppMetadata: Sendable {
    public struct LaunchEntry: Sendable, Equatable {
        public let index: String
        public let executable: String
        public let arguments: String
        public let workingDir: String
        public let osList: [String]      // empty = any OS
        public let osArch: String        // "", "32" or "64"
        public let type: String          // "default", "option1", "none", ...
        public let description: String
        /// Entries tied to a beta branch only appear for testers on that branch.
        public let betaKey: String

        public var isWindows: Bool { osList.isEmpty || osList.contains("windows") }
        /// Usable by a normal player of the Windows build: not a VR mode, editor,
        /// dedicated server, benchmark or hidden entry.
        public var isPlayableWindowsEntry: Bool { isLaunchableWindowsEntry && isPlayerLaunchType }
        public var parsedArguments: [String] { AppMetadata.commandLineArguments(arguments) }

        var isLaunchableWindowsEntry: Bool { isWindows && !executable.isEmpty && type.lowercased() != "none" && betaKey.isEmpty }
        var isPlayerLaunchType: Bool {
            let t = type.lowercased()
            return t.isEmpty || t == "default" || (t.hasPrefix("option") && t.dropFirst(6).allSatisfy(\.isNumber))
        }
    }

    public let appid: UInt32
    public let name: String
    public let type: String
    public let osList: [String]
    public let installDir: String
    public let launch: [LaunchEntry]

    public var hasMacBuild: Bool { osList.contains("macos") }
    public var isWindowsOnly: Bool { !hasMacBuild && (osList.isEmpty || osList.contains("windows")) }

    public init?(appid: UInt32, info: KeyValues) {
        let root = info["appinfo"] ?? info
        guard let common = root["common"] else { return nil }
        self.appid = appid
        self.name = common["name"]?.string ?? "App \(appid)"
        self.type = common["type"]?.string ?? ""
        self.osList = Self.split(common["oslist"]?.string)
        self.installDir = root[path: "config", "installdir"]?.string ?? ""
        self.launch = (root[path: "config", "launch"]?.children ?? []).map { index, entry in
            LaunchEntry(index: index,
                        executable: Self.normalizeExecutable(entry["executable"]?.string ?? ""),
                        arguments: entry["arguments"]?.string ?? "",
                        workingDir: entry["workingdir"]?.string ?? "",
                        osList: Self.split(entry[path: "config", "oslist"]?.string),
                        osArch: entry[path: "config", "osarch"]?.string ?? "",
                        type: entry["type"]?.string ?? "",
                        description: entry["description"]?.string ?? "",
                        betaKey: entry[path: "config", "BetaKey"]?.string ?? "")
        }
    }

    /// The launch entry Vapor should use for the Windows build: the default
    /// Windows entry, preferring 64-bit when both bitnesses exist.
    public var windowsLaunch: LaunchEntry? {
        // A VR-only or tool-only app still has to start somehow.
        let player = windowsLaunchEntries
        let candidates = player.isEmpty ? launch.filter(\.isLaunchableWindowsEntry) : player
        let defaults = candidates.filter { $0.type.isEmpty || $0.type.lowercased() == "default" }
        let pool = defaults.isEmpty ? candidates : defaults
        return pool.first { $0.osArch == "64" } ?? pool.first { $0.osArch.isEmpty } ?? pool.first
    }

    /// All Windows launch entries a normal player can pick (no beta-only ones).
    public var windowsLaunchEntries: [LaunchEntry] { launch.filter(\.isPlayableWindowsEntry) }

    /// Arguments from a Steam command line (a launch entry's `arguments`, or the user's
    /// launch options). With `%command%`, only what follows it is passed to the game: what
    /// precedes it is a wrapper/env prefix Vapor already controls.
    public static func commandLineArguments(_ options: String) -> [String] {
        var s = options.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "%command%") { s = String(s[r.upperBound...]) }
        var out: [String] = [], cur = "", quote: Character?
        for c in s {
            if let q = quote { if c == q { quote = nil } else { cur.append(c) } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == " " || c == "\t" { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(c) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Steam paths use backslashes and sometimes a leading separator.
    static func normalizeExecutable(_ s: String) -> String {
        var p = s.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    private static func split(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
