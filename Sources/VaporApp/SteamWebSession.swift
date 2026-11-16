import SwiftUI
import VaporKit
import WebKit

/// Vapor's web data store, signed in as the Windows Steam account. Everything Vapor shows is native;
/// this session is what checkout (the one web step) and the community requests that need a login use.
@MainActor
final class SteamWebSession: ObservableObject {
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// Persistent website data of Vapor's own, separate from Safari's.
    static let dataStoreID = UUID(uuidString: "5A0C9D2E-7F43-4E61-9C3B-1D2E3F405A6B")!

    /// The account whose web session the store holds, while it is the Windows Steam client's.
    @Published private(set) var linkedSteamID: String?
    var linked: Bool { linkedSteamID != nil }
    /// Every host's steamLoginSecure as last copied, so a refresh on any host is picked up.
    private var appliedLogins: Set<String> = []
    private var linkGeneration = 0

    /// Keeps the web data store signed in as the Windows Steam account (its web session cookies, in Chinese) for
    /// as long as the calling task runs: retries until the client has a web login, then follows it when
    /// Steam refreshes it, signs out or switches account. Signed out again when the task is cancelled.
    func link(to ui: SteamUI) async {
        linkGeneration += 1
        let generation = linkGeneration
        var checked = Date.distantPast
        while !Task.isCancelled {
            if !linked || checked.timeIntervalSinceNow < -30, let cookies = try? await ui.webCookies(), !Task.isCancelled {
                checked = .now
                // Each Steam host holds its own token; the store's decides the account, all of them decide a refresh.
                let logins = cookies.filter { $0.name == "steamLoginSecure" }
                let primary = logins.first { $0.domain.trimmingCharacters(in: ["."]) == "store.steampowered.com" }
                    ?? logins.min { ($0.domain, $0.value) < ($1.domain, $1.value) }
                if let login = primary?.value, let id = SteamLink.steamID(loginCookie: login) {
                    let all = Set(logins.map { "\($0.domain)\t\($0.value)" })
                    if all != appliedLogins { await apply(cookies, login: login, steamID: id); appliedLogins = all }
                    if linkedSteamID != id { linkedSteamID = id }
                } else if linkedSteamID != nil {
                    linkedSteamID = nil
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if generation == linkGeneration { unlink() }
    }

    /// The client signed out or its session changed: show the session as not linked until `link` has
    /// copied the new session (within a couple of seconds while it runs).
    func unlink() {
        if linkedSteamID != nil { linkedSteamID = nil }
        appliedLogins = []
    }

    private func apply(_ cookies: [SteamUI.Cookie], login: String, steamID: String) async {
        let store = WKWebsiteDataStore(forIdentifier: Self.dataStoreID).httpCookieStore
        let held = await store.allCookies().filter { c in
            URL(string: "https://\(c.domain.trimmingCharacters(in: ["."]))/").map(SteamLink.isSteamWeb) ?? false
        }
        let logins = held.filter { $0.name == "steamLoginSecure" }
        // The data store persists across launches and may still hold another account's cart and session.
        if logins.contains(where: { SteamLink.steamID(loginCookie: $0.value) != steamID }) {
            for c in held { await store.deleteCookie(c) }
        }
        for c in cookies {
            var props: [HTTPCookiePropertyKey: Any] = [.name: c.name, .value: c.value, .domain: c.domain, .path: c.path]
            if c.secure { props[.secure] = "TRUE" }
            if c.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
        }
        for host in ["store.steampowered.com", "steamcommunity.com", "checkout.steampowered.com", "help.steampowered.com"] {
            if let lang = HTTPCookie(properties: [.name: "Steam_Language", .value: "schinese", .domain: host, .path: "/", .secure: "TRUE"]) {
                await store.setCookie(lang)
            }
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
