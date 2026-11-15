import Foundation

/// What a steam:// URL on a store page means for Vapor. In client mode the store's buttons are
/// steam:// links (Install / Play Now → `steam://launch/<appid>/Dialog`, outbound links →
/// `steam://openurl_external/<url>`); Windows Steam would handle them itself, Vapor routes them.
public enum SteamLink: Equatable, Sendable {
    case play(UInt32)           // launch / run: play if installed, otherwise install
    case install(UInt32)        // install / installaddon / preload
    case page(URL)              // open inside the store view
    case external(URL)          // open in the default browser; always http(s)
    case ignore

    public init(_ url: URL) {
        guard url.scheme?.lowercased() == "steam", let host = url.host else { self = .ignore; return }
        let rest = String(url.absoluteString.dropFirst("steam://\(host)/".count))
        let appid = url.pathComponents.dropFirst().first.flatMap(UInt32.init)
        switch host.lowercased() {
        case "launch", "run", "rungameid":
            self = appid.map(SteamLink.play) ?? .ignore
        case "install", "installaddon", "preload":
            self = appid.map(SteamLink.install) ?? .ignore
        case "store":
            self = appid.map { .page(URL(string: "https://store.steampowered.com/app/\($0)/")!) } ?? .ignore
        case "openurl":
            self = Self.webURL(rest).map { Self.isSteamWeb($0) ? .page($0) : .external($0) } ?? .ignore
        case "openurl_external":
            self = Self.webURL(rest).map(SteamLink.external) ?? .ignore
        default:
            self = .ignore
        }
    }

    /// `s` as a URL only if it is http(s) with a host: anything else handed to the system could open
    /// another app, mount a share or run a file.
    public static func webURL(_ s: String) -> URL? {
        URL(string: s).flatMap { isWeb($0) ? $0 : nil }
    }

    public static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && !(url.host ?? "").isEmpty
    }

    public static func isSteamWeb(_ url: URL) -> Bool {
        guard isWeb(url), let host = url.host?.lowercased() else { return false }
        return ["steampowered.com", "steamcommunity.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The SteamID64 a `steamLoginSecure` cookie belongs to; its value is `<steamid64>||<token>`,
    /// usually percent-encoded.
    public static func steamID(loginCookie value: String) -> String? {
        let id = value.prefix { ("0"..."9").contains($0) }
        let sep = value.dropFirst(id.count)
        guard id.count == 17, sep.hasPrefix("||") || sep.uppercased().hasPrefix("%7C%7C") else { return nil }
        return String(id)
    }
}
