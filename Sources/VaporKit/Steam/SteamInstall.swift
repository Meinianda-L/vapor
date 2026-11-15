import Foundation

/// A Steam client installation: the native macOS client, or a Windows client
/// living inside a Wine prefix. Both share the same on-disk layout.
public struct SteamInstall: Sendable {
    public enum Kind: String, Sendable { case native, wine }

    public let kind: Kind
    public let root: URL
    /// Wine prefix that contains this install (nil for native).
    public let prefix: URL?

    public static var nativeDefault: SteamInstall {
        SteamInstall(kind: .native, root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam"), prefix: nil)
    }

    /// Windows Steam inside a prefix at the default location.
    public static func wine(prefix: URL) -> SteamInstall {
        SteamInstall(kind: .wine, root: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam"), prefix: prefix)
    }

    public init(kind: Kind, root: URL, prefix: URL?) {
        self.kind = kind; self.root = root; self.prefix = prefix
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) }
    public var appInfoURL: URL { root.appendingPathComponent("appcache/appinfo.vdf") }

    /// Maps a path as written by this Steam client (e.g. `C:\\Games`) to a host URL.
    public func hostURL(for steamPath: String) -> URL {
        guard kind == .wine, let prefix, steamPath.count >= 2, steamPath.dropFirst().first == ":" else {
            return URL(fileURLWithPath: steamPath)
        }
        let drive = steamPath.prefix(1).lowercased()
        let rest = steamPath.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        let driveRoot = prefix.appendingPathComponent("dosdevices/\(drive):").resolvingSymlinksInPath()
        return URL(fileURLWithPath: driveRoot.path + rest)
    }

    /// All `steamapps` folders registered in `libraryfolders.vdf` (always includes the root).
    public func libraryFolders() -> [URL] {
        var folders = [root.appendingPathComponent("steamapps")]
        let url = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let kv = try? TextVDF.parse(contentsOf: url), let lib = kv["libraryfolders"] {
            for (_, entry) in lib.children {
                guard let path = entry["path"]?.string else { continue }
                let steamapps = hostURL(for: path).appendingPathComponent("steamapps").standardizedFileURL
                if !folders.contains(where: { $0.standardizedFileURL.path == steamapps.path }) { folders.append(steamapps) }
            }
        }
        return folders
    }

    public func installedApps() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in libraryFolders() {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                if let app = InstalledApp(manifest: file, library: folder) { apps.append(app) }
            }
        }
        return apps.sorted { $0.appid < $1.appid }
    }

    public func users() -> [SteamUser] {
        let url = root.appendingPathComponent("config/loginusers.vdf")
        guard let kv = try? TextVDF.parse(contentsOf: url), let users = kv["users"] else { return [] }
        return users.children.compactMap { id, info in
            guard let id64 = UInt64(id) else { return nil }
            return SteamUser(steamID64: id64,
                             personaName: info["PersonaName"]?.string ?? "",
                             mostRecent: info["MostRecent"]?.string == "1")
        }
    }

    public func localConfigURL(for user: SteamUser) -> URL {
        root.appendingPathComponent("userdata/\(user.accountID)/config/localconfig.vdf")
    }
}

public struct SteamUser: Sendable, Equatable {
    public let steamID64: UInt64
    public let personaName: String
    public let mostRecent: Bool
    public var accountID: UInt64 { steamID64 - 76_561_197_960_265_728 }
}

/// One `appmanifest_<appid>.acf`.
public struct InstalledApp: Sendable {
    public let appid: UInt32
    public let name: String
    public let installDir: URL
    public let stateFlags: Int64
    public let buildID: String
    public let manifest: URL

    /// StateFlags bit 2 (value 4) = fully installed.
    public var isFullyInstalled: Bool { stateFlags & 4 != 0 }

    init?(manifest: URL, library: URL) {
        guard let kv = try? TextVDF.parse(contentsOf: manifest), let state = kv["AppState"],
              let appid = state["appid"]?.int, let dir = state["installdir"]?.string else { return nil }
        self.appid = UInt32(appid)
        self.name = state["name"]?.string ?? "App \(appid)"
        self.installDir = library.appendingPathComponent("common").appendingPathComponent(dir)
        self.stateFlags = state["StateFlags"]?.int ?? 0
        self.buildID = state["buildid"]?.string ?? ""
        self.manifest = manifest
    }
}
