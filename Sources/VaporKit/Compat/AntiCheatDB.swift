import Foundation

/// AreWeAntiCheatYet data (https://areweanticheatyet.com), keyed by Steam AppID.
/// Status describes Linux/Proton, which ships EAC and BattlEye runtimes that macOS Wine
/// lacks, so Supported/Running/Broken say little here. Only Denied, a developer refusing
/// Wine/Proton, is a hard signal.
public struct AntiCheatDB: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let status: String          // Supported, Running, Planned, Broken, Denied, Unknown
        public let antiCheats: [String]
        public let dateChanged: String

        static let kernelLevelNames = ["denuvo anti-cheat", "vanguard", "ricochet", "javelin", "gameguard",
                                       "xigncode", "anti-cheat expert", "mhyprot", "faceit", "equ8"]
        /// Kernel-level anti-cheats among `antiCheats`; they never run under Wine.
        public var kernelLevelAntiCheats: [String] {
            antiCheats.filter { n in Self.kernelLevelNames.contains { n.lowercased().contains($0) } }
        }
    }

    public let entries: [UInt32: Entry]

    /// Heroic keeps a cached copy; Vapor reuses it when present.
    public static var heroicCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/heroic/areweanticheatyet.json")
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        struct Raw: Decodable {
            let name: String
            let status: String
            let anticheats: [String]?
            let storeIds: [String: AnyStoreID]?
            let dateChanged: String?
        }
        struct AnyStoreID: Decodable {
            let steam: String?
            init(from decoder: Decoder) throws { steam = try? decoder.singleValueContainer().decode(String.self) }
        }
        var map: [UInt32: Entry] = [:]
        for r in try JSONDecoder().decode([Raw].self, from: data) {
            guard let id = r.storeIds?["steam"]?.steam.flatMap(UInt32.init) else { continue }
            map[id] = Entry(name: r.name, status: r.status, antiCheats: r.anticheats ?? [], dateChanged: r.dateChanged ?? "")
        }
        entries = map
    }

    public init(entries: [UInt32: Entry]) { self.entries = entries }

    public subscript(appid: UInt32) -> Entry? { entries[appid] }
}
