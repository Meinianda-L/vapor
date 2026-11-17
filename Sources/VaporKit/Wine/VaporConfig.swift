import Foundation

/// Where Vapor keeps its own engines, renderer packs, downloads, prefixes and config.
/// `VAPOR_HOME` moves all of it, so tests and dry runs never touch the real folders.
public struct VaporLocations: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: VaporLocations {
        if let custom = ProcessInfo.processInfo.environment["VAPOR_HOME"], !custom.isEmpty {
            return VaporLocations(root: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        return VaporLocations(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vapor", isDirectory: true))
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    /// Per-renderer clones of a base engine (see VariantBuilder). Lives inside Engines but is not an engine.
    public var variants: URL { engines.appendingPathComponent(Self.variantsFolder, isDirectory: true) }
    public var packs: URL { root.appendingPathComponent("Packs", isDirectory: true) }
    public func packs(_ kind: PackKind) -> URL { packs.appendingPathComponent(kind.rawValue, isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var prefixes: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    public var defaultSteamPrefix: URL { prefixes.appendingPathComponent("Steam", isDirectory: true) }

    static let variantsFolder = "Variants"
}

/// Vapor's own settings: which engine runs Windows Steam and which prefix it lives in.
/// Unset fields fall back to the Heroic layout this project started from.
public struct VaporConfig: Codable, Sendable, Equatable {
    /// Wine root containing bin/wine and bin/wineserver.
    public var engineRoot: String?
    /// Wine prefix holding Windows Steam.
    public var steamPrefix: String?

    public init(engineRoot: String? = nil, steamPrefix: String? = nil) {
        self.engineRoot = engineRoot
        self.steamPrefix = steamPrefix
    }

    public var engineURL: URL? { engineRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    public var steamPrefixURL: URL? { steamPrefix.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// A missing or unreadable file reads as an empty config.
    public static func load(from url: URL = VaporLocations.standard.config) -> VaporConfig {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(VaporConfig.self, from: data) else {
            return VaporConfig()
        }
        return config
    }

    public func save(to url: URL = VaporLocations.standard.config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Errors from engine discovery, downloads, variant building and prefix setup, worded for the UI.
public enum WineSetupError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case network(String)
    case rateLimited
    case httpStatus(Int)
    case badReleaseData
    case unknownAsset(String)
    case checksumMismatch(String)
    case notEnoughSpace(needed: Int64)
    case extractFailed(String)
    case invalidEngine(String)
    case invalidPack(PackKind, String)
    case engineUnusable(String)
    case noPack(PackKind)
    case copyFailed(String)
    case processFailed(String, Int32)
    case timeout(String)
    case steamNotInstalled

    public var description: String {
        switch self {
        case let .network(m): return String(localized: "网络错误：\(m)")
        case .rateLimited: return String(localized: "GitHub 接口访问次数已达上限，请过一会儿再试。")
        case let .httpStatus(code): return String(localized: "下载失败（HTTP \(code)）。")
        case .badReleaseData: return String(localized: "无法解析 GitHub 返回的版本信息。")
        case let .unknownAsset(name): return String(localized: "找不到可下载的 \(name)。")
        case let .checksumMismatch(name): return String(localized: "\(name) 校验失败，文件可能不完整，请重新下载。")
        case let .notEnoughSpace(needed):
            return String(localized: "磁盘空间不足：需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) 的可用空间。")
        case let .extractFailed(m): return String(localized: "解压失败：\(m)")
        case let .invalidEngine(name): return String(localized: "\(name) 里没有找到 bin/wine，不是可用的 Wine 引擎。")
        case let .invalidPack(kind, name): return String(localized: "\(name) 不是有效的 \(kind.displayName) 渲染包。")
        case let .engineUnusable(reason): return String(localized: "这个引擎不能用于 Vapor：\(reason)")
        case let .noPack(kind): return String(localized: "没有找到 \(kind.displayName) 渲染包。")
        case let .copyFailed(m): return String(localized: "复制引擎失败：\(m)")
        case let .processFailed(tool, code): return String(localized: "\(tool) 运行失败（退出码 \(code)）。")
        case let .timeout(what): return String(localized: "\(what) 超时。")
        case .steamNotInstalled: return String(localized: "Steam 安装程序已结束，但没有找到 steam.exe。")
        }
    }

    public var errorDescription: String? { description }
}
