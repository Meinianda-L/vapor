import Foundation

/// Library artwork for an app: Steam's local cache first, then Steam's CDN.
public enum Artwork {
    public enum Kind: Sendable, CaseIterable {
        case cover      // 600x900 portrait capsule
        case hero       // wide banner behind the game page
        case logo       // transparent title logo
        case header     // 460x215 landscape capsule

        /// File names Steam uses in appcache/librarycache, newest layout last.
        var cacheNames: [String] {
            switch self {
            case .cover: return ["library_600x900.jpg", "library_capsule.jpg"]
            case .hero: return ["library_hero.jpg"]
            case .logo: return ["logo.png"]
            case .header: return ["header.jpg", "library_header.jpg"]
            }
        }

        var cdnName: String {
            switch self {
            case .cover: return "library_600x900.jpg"
            case .hero: return "library_hero.jpg"
            case .logo: return "logo.png"
            case .header: return "header.jpg"
            }
        }
    }

    /// Looks in each install's `appcache/librarycache/<appid>`, including the hashed
    /// sub-folders newer clients use.
    public static func local(appid: UInt32, kind: Kind, installs: [SteamInstall]) -> URL? {
        let fm = FileManager.default
        for install in installs {
            let dir = install.root.appendingPathComponent("appcache/librarycache/\(appid)")
            guard fm.fileExists(atPath: dir.path) else { continue }
            for name in kind.cacheNames {
                let direct = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: direct.path) { return direct }
            }
            let subdirs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for sub in subdirs {
                for name in kind.cacheNames {
                    let nested = sub.appendingPathComponent(name)
                    if fm.fileExists(atPath: nested.path) { return nested }
                }
            }
        }
        return nil
    }

    public static func remote(appid: UInt32, kind: Kind) -> URL {
        URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appid)/\(kind.cdnName)")!
    }
}
