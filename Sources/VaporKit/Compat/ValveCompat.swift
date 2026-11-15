import Foundation

/// Valve's server-side Steam Play data, delivered to every client as the
/// extended section of app 891390 ("SteamPlay 2.0 Manifests") in appinfo.
public struct ValveCompatManifest: Sendable {
    public static let appid: UInt32 = 891_390

    public struct Mapping: Sendable, Equatable {
        public let tool: String
        public let platform: String
        public let comment: String
    }

    /// Per-game Proton quirk flags, e.g. ["noesync", "cmdlineappend:-dx11"].
    public let configs: [UInt32: [String]]
    /// Per-game compat-tool pins (e.g. a specific Proton version).
    public let mappings: [UInt32: Mapping]

    public init(appInfo: AppInfo) {
        let ext = appInfo[Self.appid]?[path: "appinfo", "extended"]
        var configs: [UInt32: [String]] = [:]
        for (_, entry) in ext?["app_compat_configs"]?.children ?? [] {
            guard let id = entry["appid"]?.int, let config = entry["config"]?.string else { continue }
            configs[UInt32(id)] = Self.splitFlags(config)
        }
        var mappings: [UInt32: Mapping] = [:]
        for (_, entry) in ext?["app_mappings"]?.children ?? [] {
            guard let id = entry["appid"]?.int else { continue }
            mappings[UInt32(id)] = Mapping(tool: entry["tool"]?.string ?? "",
                                           platform: entry["platform"]?.string ?? "",
                                           comment: entry["comment"]?.string ?? "")
        }
        self.configs = configs
        self.mappings = mappings
    }

    /// Proton separates flags with commas; a `\,` keeps a comma inside a value.
    static func splitFlags(_ config: String) -> [String] {
        var flags: [String] = [], current = ""
        var chars = config.makeIterator()
        while let c = chars.next() {
            if c == "\\", let n = chars.next() { current.append(n); continue }
            if c == "," { flags.append(current); current = ""; continue }
            current.append(c)
        }
        flags.append(current)
        return flags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "none" }
    }
}

/// What a Wine engine supports, which decides whether a Proton quirk can be honoured.
public struct EngineCapabilities: Sendable, Equatable {
    /// Wine-staging style env switches (WINE_LARGE_ADDRESS_AWARE, ...).
    public var stagingEnv: Bool
    /// Proton-only patches (WINE_HEAP_DELAY_FREE, WINE_DISABLE_WRITE_WATCH, ...).
    public var protonPatches: Bool

    public init(stagingEnv: Bool, protonPatches: Bool) {
        self.stagingEnv = stagingEnv; self.protonPatches = protonPatches
    }
    public static let crossOverBased = EngineCapabilities(stagingEnv: true, protonPatches: false)
}

/// Wine settings for one game, produced by quirk translation and later layers.
public struct WineSettings: Sendable, Equatable {
    public var env: [String: String] = [:]
    public var dllOverrides: [String: String] = [:]
    public var extraArguments: [String] = []
    public var useMsync = true
    /// Map the game directory to its own drive letter (Proton's "gamedrive").
    public var gameDrive = false
    /// Backend ordering hints for the renderer ladder.
    public var avoidD3D10Translation = false

    public init() {}

    public var dllOverridesString: String {
        dllOverrides.keys.sorted().map { "\($0)=\(dllOverrides[$0]!)" }.joined(separator: ";")
    }
}

public struct QuirkResolution: Sendable, Equatable {
    public enum Status: String, Sendable {
        case applied            // same effect as on Proton
        case approximated       // closest macOS equivalent
        case notApplicable      // Linux/NVIDIA-specific, nothing to do on macOS
        case engineUnsupported  // needs a Wine build with that patch
        case unknown            // flag Vapor does not know yet
    }
    public let flag: String
    public let status: Status
    public let effect: String
}

/// Translates Valve's Proton quirk flags into macOS Wine settings.
public enum QuirkTranslator {
    public static func translate(_ flags: [String], engine: EngineCapabilities) -> (WineSettings, [QuirkResolution]) {
        var s = WineSettings()
        var out: [QuirkResolution] = []
        func note(_ flag: String, _ status: QuirkResolution.Status, _ effect: String) {
            out.append(QuirkResolution(flag: flag, status: status, effect: effect))
        }
        func stagingEnv(_ flag: String, _ key: String, _ value: String, needsProton: Bool = false) {
            let ok = needsProton ? engine.protonPatches : engine.stagingEnv
            if ok { s.env[key] = value; note(flag, .applied, "\(key)=\(value)") }
            else { note(flag, .engineUnsupported, "needs \(needsProton ? "Proton" : "staging") patch for \(key)") }
        }

        for flag in flags {
            let name = flag.split(separator: ":", maxSplits: 1).first.map(String.init) ?? flag
            let value = flag.contains(":") ? String(flag.split(separator: ":", maxSplits: 1)[1]) : ""
            switch name {
            case "noesync", "nofsync":
                s.useMsync = false
                note(flag, name == "noesync" ? .applied : .approximated, "msync disabled (macOS replacement for esync/fsync)")
            case "forcelgadd": stagingEnv(flag, "WINE_LARGE_ADDRESS_AWARE", "1")
            case "noforcelgadd": stagingEnv(flag, "WINE_LARGE_ADDRESS_AWARE", "0")
            case "heapdelayfree": stagingEnv(flag, "WINE_HEAP_DELAY_FREE", "1", needsProton: true)
            case "nowritewatch": stagingEnv(flag, "WINE_DISABLE_WRITE_WATCH", "1", needsProton: true)
            case "usenativexinput13":
                s.dllOverrides["xinput1_3"] = "n,b"
                note(flag, .applied, "xinput1_3=n,b")
            case "nativevulkanloader":
                s.dllOverrides["vulkan-1"] = "n,b"
                note(flag, .applied, "vulkan-1=n,b")
            case "disablelibglesv2":
                s.dllOverrides["libglesv2"] = "d"
                note(flag, .applied, "libglesv2 disabled")
            case "gamedrive":
                s.gameDrive = true
                note(flag, .applied, "game directory mapped to its own drive letter")
            case "cmdlineappend":
                s.extraArguments.append(value)
                note(flag, .applied, "argument \(value)")
            case "nod3d10":
                s.avoidD3D10Translation = true
                note(flag, .approximated, "D3D10 kept on WineD3D instead of DXMT/DXVK")
            case "enablenvapi":
                note(flag, .approximated, "use the backend's own nvapi64 (D3DMetal/DXMT ship one)")
            case "oldglstr":
                note(flag, .notApplicable, "macOS OpenGL extension strings are short; overflow unlikely")
            case "hidenvgpu":
                note(flag, .notApplicable, "no NVIDIA GPU on Apple silicon")
            case "seccomp":
                note(flag, .notApplicable, "Linux seccomp")
            case "vkd3dbindlesstb", "vkd3dfl12":
                note(flag, .notApplicable, "vkd3d-proton option; D3D12 uses D3DMetal on macOS")
            default:
                note(flag, .unknown, "not mapped yet")
            }
        }
        return (s, out)
    }
}
