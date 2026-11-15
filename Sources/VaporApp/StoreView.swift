import SwiftUI
import VaporKit
import WebKit

/// The Steam store, signed in as the Windows Steam account, with Vapor's install/play controls placed
/// on app pages using the store's own button styles. Pages run in normal browser mode (client-mode
/// pages expect Steam's CEF bridge and break in WebKit); downloads go through the headless client.
@MainActor
final class StoreModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let home = URL(string: "https://store.steampowered.com/")!
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// Persistent website data (HTTP cache!) of Vapor's own, separate from Safari's. The Steam CDN is
    /// slow from here; like the client's htmlcache, the cache is what makes pages fast after the first visit.
    static let dataStoreID = UUID(uuidString: "5A0C9D2E-7F43-4E61-9C3B-1D2E3F405A6B")!

    @Published var title = "Steam 商店"
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress = 0.0
    @Published private(set) var url: URL?
    /// The account whose web session the store holds, while it is the Windows Steam client's.
    @Published private(set) var linkedSteamID: String?
    var linked: Bool { linkedSteamID != nil }
    /// An app the page asked to install.
    @Published var request: UInt32?
    /// An app the page asked to play; installs it instead when it is not installed.
    @Published var playRequest: UInt32?
    /// The app page currently shown, whether the page itself says it is owned, and whether it is
    /// something Steam installs on its own (not a DLC or soundtrack).
    @Published private(set) var pageApp: (id: UInt32, ownedOnPage: Bool, installable: Bool)?
    /// Pages opened with window.open or a form's target=_blank, shown over the store, newest last.
    @Published private(set) var popups: [Popup] = []

    struct Popup: Identifiable {
        let webView: WKWebView
        let size: CGSize
        var title = ""
        var id: ObjectIdentifier { ObjectIdentifier(webView) }
    }

    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []
    private var popupObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var appliedLogin: String?
    /// Every host's steamLoginSecure as last copied, so a refresh on any host is picked up.
    private var appliedLogins: Set<String> = []
    private var linkGeneration = 0

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.chromeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.appPageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.browserAgent
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        content.add(WeakHandler(self), name: "vapor")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.estimatedProgress) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
            webView.observe(\.url) { [weak self] w, _ in Task { @MainActor in self?.url = w.url } },
        ]
        webView.load(URLRequest(url: Self.home))   // preload at launch, before the store is opened
    }

    /// A store path ("" for the front page) or a full URL.
    func go(_ path: String) {
        let url = path.hasPrefix("https://") ? URL(string: path) : URL(string: path, relativeTo: Self.home)?.absoluteURL
        webView.load(URLRequest(url: url ?? Self.home))
    }

    enum Section { case store, community, profile }

    /// Which top-level tab the current page belongs to, like the client's STORE / COMMUNITY / profile.
    func section(steamID: String?) -> Section {
        guard let url, let host = url.host else { return .store }
        if host.hasSuffix("steamcommunity.com") {
            if let id = steamID, url.path.contains("/profiles/\(id)") || url.path.hasPrefix("/id/") { return .profile }
            return .community
        }
        return .store
    }

    /// Keeps the store signed in as the Windows Steam account (its web session cookies, in Chinese) for
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

    /// The client signed out or its session changed: show the store as not linked until `link` has
    /// copied the new session (within a couple of seconds while it runs).
    func unlink() {
        if linkedSteamID != nil { linkedSteamID = nil }
        appliedLogin = nil
        appliedLogins = []
    }

    private func apply(_ cookies: [SteamUI.Cookie], login: String, steamID: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
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
        // Pages already show this session when the store held it, or when Steam only refreshed the token.
        let current = logins.contains { $0.value == login } || appliedLogin.flatMap { SteamLink.steamID(loginCookie: $0) } == steamID
        appliedLogin = login
        if !current { webView.reload() }
    }

    /// Pushes Vapor's view of the current app (owned, installed, downloading …) into the page.
    func show(_ state: AppPageState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        webView.evaluateJavaScript("window.__vaporState && window.__vaporState(\(String(decoding: data, as: UTF8.self)))")
    }

    // MARK: page messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Every frame of every page sees the handler, including iframes, popups and sites reached
        // through linkfilter; only the store page in the main view may ask for installs.
        let frame = message.frameInfo
        guard message.webView === webView, frame.isMainFrame,
              frame.securityOrigin.protocol == "https", frame.securityOrigin.host == "store.steampowered.com",
              let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
        let appid = (body["appid"] as? NSNumber)?.uint32Value ?? 0
        switch kind {
        case "ready": pageApp = (appid, body["owned"] as? Bool ?? false, !(body["addon"] as? Bool ?? false))
        case "install" where appid == pageApp?.id: request = appid
        case "play" where appid == pageApp?.id: playRequest = appid
        default: break
        }
    }

    // MARK: steam:// links (Play Game on free titles, community links …)

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme?.lowercased() == "steam" else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        follow(SteamLink(url), from: action, in: webView)
    }

    /// Plain clicked links: Steam pages stay in the view, other sites go to the browser. Everything
    /// else (window.open, form posts, about:blank written by script) gets a real child view, so POST
    /// bodies and window.opener keep working for checkout, payment providers and sign-in.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        if let url, url.scheme?.lowercased() == "steam" {
            follow(SteamLink(url), from: action, in: webView)
            return nil
        }
        if let url, SteamLink.isWeb(url), action.navigationType == .linkActivated, action.request.httpMethod ?? "GET" == "GET" {
            if SteamLink.isSteamWeb(url) { webView.load(action.request) } else { openInBrowser(url) }
            return nil
        }
        if let url, url.scheme?.lowercased() == "mailto", action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)   // the mail client, as before; file:, smb: and the like stay blocked
            return nil
        }
        guard url.map({ SteamLink.isWeb($0) || $0.absoluteString.isEmpty || $0.absoluteString == "about:blank" }) ?? true else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.customUserAgent = Self.browserAgent
        child.navigationDelegate = self
        child.uiDelegate = self
        let size = CGSize(width: windowFeatures.width.map { CGFloat($0.doubleValue) } ?? 520,
                          height: windowFeatures.height.map { CGFloat($0.doubleValue) } ?? 700)
        let popup = Popup(webView: child, size: size, title: url?.host ?? "")
        let retitle: (WKWebView) -> Void = { [weak self, id = popup.id] w in
            let title = w.title.flatMap { $0.isEmpty ? nil : $0 } ?? w.url?.host ?? ""
            Task { @MainActor in
                guard let self, let i = self.popups.firstIndex(where: { $0.id == id }) else { return }
                self.popups[i].title = title
            }
        }
        popupObservers[popup.id] = [child.observe(\.title) { w, _ in retitle(w) }, child.observe(\.url) { w, _ in retitle(w) }]
        popups.append(popup)
        return child   // WebKit loads the request into it; loading it again would resubmit a POST
    }

    func webViewDidClose(_ webView: WKWebView) { closePopup(ObjectIdentifier(webView)) }

    /// Closes a popup and any it opened in turn.
    func closePopup(_ id: ObjectIdentifier) {
        guard let i = popups.firstIndex(where: { $0.id == id }) else { return }
        for p in popups[i...] {
            p.webView.stopLoading()
            popupObservers[p.id] = nil
        }
        popups.removeSubrange(i...)
    }

    /// steam:// links act only when a Steam page asked; an ad or third-party iframe cannot start games.
    private func follow(_ link: SteamLink, from action: WKNavigationAction, in webView: WKWebView) {
        guard let source = action.sourceFrame as WKFrameInfo?,
              let origin = URL(string: "\(source.securityOrigin.protocol)://\(source.securityOrigin.host)/"),
              SteamLink.isSteamWeb(origin) else { return }
        switch link {
        case let .play(id): playRequest = id
        case let .install(id): request = id
        case let .page(u): webView.load(URLRequest(url: u))
        case let .external(u): openInBrowser(u)
        case .ignore: break
        }
    }

    private func openInBrowser(_ url: URL) {
        guard SteamLink.isWeb(url) else { return }
        NSWorkspace.shared.open(url)
    }

    // Popups share these callbacks but not the store's toolbar or app-page state.

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loading = true
    }

    /// The document is replaced only now: a failed, stopped or cancelled navigation keeps the page,
    /// and its block, on screen.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        pageApp = nil
        syncNav()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loading = false
        syncNav()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { loading = false }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { loading = false }
    }

    private func syncNav() {
        title = webView.title.map { $0.replacingOccurrences(of: " on Steam", with: "").replacingOccurrences(of: "在 Steam 上购买 ", with: "") } ?? "Steam 商店"
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    // MARK: injected scripts

    /// Client-like chrome: no web header (Vapor's toolbar replaces it), no "Install Steam".
    static let chromeScript = """
    (() => {
      const css = `#global_header, .responsive_header, #global_action_menu .header_installsteam_btn,
        .header_installsteam_btn, #footer_spacer + #footer .valve_links,
        .game_area_already_owned_btn a[href*="/about"], a.btn_install_steam { display: none !important; }
        .responsive_page_frame { padding-top: 0 !important; }
        #vapor_action .game_area_purchase_game { padding-bottom: 18px; }
        #vapor_action .vapor_meta { color: #8f98a0; font-size: 13px; margin-top: 4px; }
        #vapor_action .vapor_bar { height: 4px; background: rgba(255,255,255,.12); border-radius: 2px; margin-top: 10px; overflow: hidden; max-width: 420px; }
        #vapor_action .vapor_bar > div { height: 100%; background: #75b022; transition: width .4s; }`;
      const s = document.createElement('style'); s.id = 'vapor_chrome'; s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    })();
    """

    /// On /app/<id>/: a purchase-area block built from the store's own classes, driven by Vapor.
    static let appPageScript = """
    (() => {
      const m = location.pathname.match(/^\\/app\\/(\\d+)/);
      if (!m || !window.webkit?.messageHandlers?.vapor) return;
      const appid = Number(m[1]);
      const post = msg => window.webkit.messageHandlers.vapor.postMessage(Object.assign({ appid }, msg));
      const owned = !!document.querySelector('.game_area_already_owned');
      const addon = !!document.querySelector('.game_area_dlc_bubble, .game_area_soundtrack_bubble');
      const name = (document.querySelector('#appHubAppName')?.textContent || '').trim();
      let box = null;
      const esc = t => String(t).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
      window.__vaporState = st => {
        if (!st || st.appid !== appid) return;
        if (!st.show) { box?.remove(); box = null; return; }
        if (!box || !document.contains(box)) {
          box = document.createElement('div');
          box.id = 'vapor_action';
          box.className = 'game_area_purchase_game_wrapper';
          const anchor = document.querySelector('#game_area_purchase');
          const owned = document.querySelector('.game_area_already_owned');
          if (anchor) anchor.prepend(box); else if (owned) owned.after(box); else return;
        }
        const button = st.button ? `<div class="game_purchase_action"><div class="game_purchase_action_bg"><div class="btn_addtocart">
            <a class="btn_green_steamui btn_medium" id="vapor_btn"><span>${esc(st.button)}</span></a></div></div></div>` : '';
        const bar = st.progress != null ? `<div class="vapor_bar"><div style="width:${Math.round(st.progress * 100)}%"></div></div>` : '';
        box.innerHTML = `<div class="game_area_purchase_game"><div class="game_area_purchase_platform"><span class="platform_img win"></span></div>
          <h1>${esc(st.title || name)}</h1><div class="vapor_meta">${esc(st.detail || '')}</div>${bar}${button}</div>`;
        box.querySelector('#vapor_btn')?.addEventListener('click', e => { e.preventDefault(); post({ type: st.action }); });
      };
      post({ type: 'ready', owned, addon });
      window.addEventListener('pageshow', e => { if (e.persisted) post({ type: 'ready', owned: !!document.querySelector('.game_area_already_owned'), addon }); });
    })();
    """
}

/// What the store page should show for one app; `action` is "install" or "play".
struct AppPageState: Encodable, Equatable {
    var appid: UInt32
    var show: Bool
    var title: String?
    var detail: String?
    var button: String?
    var action: String?
    var progress: Double?
}

/// WKUserContentController retains its handlers.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (NSObject & WKScriptMessageHandler)?
    init(_ target: NSObject & WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct StoreView: View {
    @ObservedObject var store: StoreModel
    @ObservedObject var library: LibraryStore
    @EnvironmentObject var engine: EngineModel
    var openGame: (GameItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            StoreToolbar(store: store)
            ZStack(alignment: .top) {
                WebViewHost(webView: store.webView)
                if store.loading {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent).frame(width: g.size.width * max(0.08, store.progress), height: 2)
                    }
                    .frame(height: 2)
                    .animation(.easeOut(duration: 0.2), value: store.progress)
                }
                if let popup = store.popups.last {
                    // A new identity per popup, so a nested or uncovered popup gets its own web view.
                    PopupPanel(popup: popup) { store.closePopup(popup.id) }.id(popup.id)
                }
            }
        }
        .background(Theme.background)
        .onChange(of: store.playRequest) { _, id in
            guard let id else { return }
            store.playRequest = nil
            if let game = library.games.first(where: { $0.appid == id && $0.installed }) {
                if game.installKind == .wine, game.profile != nil { engine.play(game) } else { openGame(game) }
            } else {
                store.request = id
            }
        }
        .onChange(of: store.request) { _, id in
            // Like the client, an install link for an installed game shows the game instead.
            guard let id, let game = library.games.first(where: { $0.appid == id && $0.installed }) else { return }
            store.request = nil
            openGame(game)
        }
        .onAppear { if let st = pageState { store.show(st) } }
        .onChange(of: pageState) { _, st in if let st { store.show(st) } }
        .onChange(of: store.pageApp?.id) { _, _ in if let st = pageState { store.show(st) } }
        .sheet(item: Binding(get: { store.request.flatMap { installed($0) ? nil : AppRef(id: $0) } }, set: { store.request = $0?.id })) { ref in
            InstallSheet(appid: ref.id, name: name(ref.id)) { store.request = nil }
        }
    }

    /// Links can name a demo or DLC of the page's game, so the page title is only used for the page's own app.
    private func name(_ id: UInt32) -> String {
        engine.steamApps[id]?.name ?? library.games.first { $0.appid == id }?.name
            ?? (id == store.pageApp?.id ? store.title : "App \(id)")
    }

    /// Install / download / play state for the app page on screen.
    private var pageState: AppPageState? {
        guard let page = store.pageApp else { return nil }
        let id = page.id
        let app = engine.steamApps[id]
        let game = library.games.first { $0.appid == id }
        let download = engine.downloads.first { $0.appid == id && !$0.completed }
        // Steam's install manager takes games (1), applications (2), tools (4) and demos (8); DLC and
        // soundtracks come with their game, and the store's own owned banner covers them.
        let installable = app.map { [1, 2, 4, 8].contains($0.type) } ?? page.installable
        // Library art alone is no proof of ownership: Steam keeps it after a refund.
        let owned = installable && (app != nil || page.ownedOnPage)
        var st = AppPageState(appid: id, show: false)
        guard owned || game?.installed == true || download != nil else { return st }   // the store's own purchase box
        st.show = true
        let name = app?.name ?? game?.name ?? store.title
        if let d = download {
            let o = engine.overview?.appid == id ? engine.overview : nil
            let fraction = o.map { $0.percent / 100 } ?? (d.total > 0 ? Double(d.downloaded) / Double(d.total) : 0)
            let paused = d.paused || o?.paused == true
            st.title = "\(paused ? "已暂停" : o != nil ? "正在下载" : "位于下载队列中") \(name)"
            var parts = ["\(Int(fraction * 100))%"]
            if d.total > 0 { parts.append("\(bytes(d.downloaded)) / \(bytes(d.total))") }
            if let o, o.networkBytesPerSecond > 0, !paused { parts.append("\(bytes(o.networkBytesPerSecond))/s") }
            st.detail = parts.joined(separator: " · ") + " · 由 Windows Steam 在后台下载"
            st.progress = fraction
        } else if let game, game.installed {
            st.title = "开始游戏 \(name)"
            st.detail = game.profile.map { "已安装 · \(Theme.verdictLabel($0.verdict)) · \($0.ladder.first.map { Theme.rendererLabel($0.renderer) } ?? "")" } ?? "已安装"
            st.button = "开始游戏"
            st.action = "play"
        } else {
            st.title = "在 Vapor 中安装 \(name)"
            st.detail = (engine.downloadSize(id).map { "下载约 \(bytes($0)) · " } ?? "") + "通过后台的 Windows Steam 下载，与 Steam 客户端完全一致"
            st.button = "安装"
            st.action = "install"
        }
        return st
    }
}

private struct AppRef: Identifiable { let id: UInt32 }

/// A popup page (payment provider, 3-D Secure, sign-in) over the store, like the client's own popups.
private struct PopupPanel: View {
    let popup: StoreModel.Popup
    var close: () -> Void
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black.opacity(0.5).onTapGesture {}
                VStack(spacing: 0) {
                    HStack {
                        Text(popup.title).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.text)
                        .keyboardShortcut(.cancelAction)
                        .help(engine.strings("Button_Close") ?? "关闭")
                    }
                    .padding(.leading, 14).padding(.trailing, 6)
                    .frame(height: 32)
                    WebViewHost(webView: popup.webView)
                }
                .frame(width: min(max(popup.size.width, 360), g.size.width - 40),
                       height: min(max(popup.size.height, 320) + 32, g.size.height - 40))
                .background(Theme.sidebar)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            }
        }
    }
}

extension StoreView {
    func installed(_ id: UInt32) -> Bool { library.games.contains { $0.appid == id && $0.installed } }
}

/// The client's top bar: back/forward, STORE · COMMUNITY · <persona>, then the store's own links and
/// the account (wallet) on the right. The page below renders in client mode, so it has no web header.
struct StoreToolbar: View {
    @ObservedObject var store: StoreModel
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 2) {
                    navButton("chevron.left", enabled: store.canGoBack) { store.webView.goBack() }
                    navButton("chevron.right", enabled: store.canGoForward) { store.webView.goForward() }
                }
                HStack(spacing: 20) {
                    tab("商店", .store) { store.go("") }
                    tab("社区", .community) { store.go("https://steamcommunity.com/") }
                    if let a = engine.account, !a.persona.isEmpty {
                        tab(a.persona, .profile) { store.go("https://steamcommunity.com/profiles/\(a.steamID)/") }
                    }
                }
                Spacer()
                if let a = engine.account, store.linkedSteamID == a.steamID {
                    if !a.wallet.isEmpty {
                        Text(a.wallet).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text(engine.isOnline ? "正在连接 Windows Steam…" : "启动 Windows Steam 后即可登录商店")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 34)
            HStack(spacing: 16) {
                navButton(store.loading ? "xmark" : "arrow.clockwise", enabled: true) {
                    if store.loading { store.webView.stopLoading() } else { _ = store.webView.reload() }
                }
                Text(store.url?.absoluteString ?? "")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                link("愿望单") { store.go("wishlist/") }
                link("购物车") { store.go("cart/") }
                link("兑换") { store.go("account/registerkey") }
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)                     // window traffic lights live above the content
        .padding(.bottom, 6)
        .background(Theme.background)
    }

    private func tab(_ title: String, _ section: StoreModel.Section, action: @escaping () -> Void) -> some View {
        let on = store.section(steamID: engine.account?.steamID) == section
        return Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 15, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(on ? Theme.text : Theme.secondary)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { if on { Rectangle().fill(Theme.accent).frame(height: 2) } }
        }
        .buttonStyle(.plain)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text : Theme.tertiary)
        .disabled(!enabled)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
    }
}

/// Confirms an install with the size Steam's own wizard reports.
struct InstallSheet: View {
    let appid: UInt32
    let name: String
    var dismiss: () -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var probe: SteamUI.Install?
    @State private var probing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("安装 \(name)").font(.system(size: 15, weight: .semibold))
            Group {
                if probing {
                    Text("正在向 Steam 查询大小…")
                } else if let p = probe, p.required > 0 {
                    Text("需要 \(bytes(p.required))，磁盘剩余 \(bytes(p.available))。由后台的 Windows Steam 下载。")
                } else if let size = engine.downloadSize(appid) {
                    Text("下载约 \(bytes(size))。由后台的 Windows Steam 下载。")
                } else {
                    Text("由后台的 Windows Steam 下载。")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("安装") { engine.install(appid); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(probing || (probe.map { $0.required >= $0.available && $0.available > 0 } ?? false))
            }
        }
        .padding(22)
        .frame(width: 400)
        .task {
            probe = await engine.probeInstall(appid)
            probing = false
        }
    }
}
