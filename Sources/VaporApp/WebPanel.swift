import SwiftUI
import VaporKit
import WebKit

/// Steam's web pages (discussions, guides, workshop, inventory, market, trade offers, account,
/// checkout) shown in a panel over the current screen instead of switching to the store tab. One web
/// view is reused across opens; it shares the store's signed-in session.
@MainActor
final class WebPanelModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isOpen = false
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    /// Pages opened with window.open or a form's target=_blank (payment providers), newest last.
    @Published private(set) var popups: [Popup] = []
    /// A steam:// link on a page asked to play or install this app.
    var onSteamApp: (UInt32) -> Void = { _ in }

    struct Popup: Identifiable {
        let webView: WKWebView
        let size: CGSize
        var title = ""
        var id: ObjectIdentifier { ObjectIdentifier(webView) }
    }

    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []
    private var popupObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: SteamWebSession.dataStoreID)
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.chromeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = SteamWebSession.browserAgent
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let sync: (WKWebView) -> Void = { [weak self] _ in Task { @MainActor in self?.sync() } }
        observers = [
            webView.observe(\.estimatedProgress) { w, _ in sync(w) },
            webView.observe(\.isLoading) { w, _ in sync(w) },
            webView.observe(\.title) { w, _ in sync(w) },
            webView.observe(\.url) { w, _ in sync(w) },
            webView.observe(\.canGoBack) { w, _ in sync(w) },
            webView.observe(\.canGoForward) { w, _ in sync(w) },
        ]
    }

    func open(_ url: URL) {
        guard SteamLink.isWeb(url) else { return }
        title = url.host ?? ""
        webView.load(URLRequest(url: url))
        withAnimation(.easeOut(duration: 0.2)) { isOpen = true }
    }

    /// Hides the panel and drops the page, so video and audio stop and nothing keeps running.
    func close() {
        guard isOpen else { return }
        withAnimation(.easeIn(duration: 0.16)) { isOpen = false }
        closePopup(popups.first?.id)
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func openInBrowser() {
        if let url, SteamLink.isWeb(url) { NSWorkspace.shared.open(url) }
    }

    private func sync() {
        let current = webView.url
        url = current
        loading = webView.isLoading
        progress = webView.estimatedProgress
        // about:blank is what a closed panel holds; it is never a page to go back to.
        let blank: (WKBackForwardListItem?) -> Bool = { $0.map { $0.url.absoluteString == "about:blank" } ?? true }
        canGoBack = !blank(webView.backForwardList.backItem)
        canGoForward = webView.canGoForward
        if current?.absoluteString != "about:blank" {
            title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? current?.host ?? ""
        }
    }

    // MARK: links

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        if url.scheme?.lowercased() == "steam" {
            decisionHandler(.cancel)
            follow(SteamLink(url), from: action)
        } else if webView === self.webView, action.navigationType == .linkActivated, SteamLink.isWeb(url), !SteamLink.isSteamWeb(url) {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        } else {
            decisionHandler(.allow)
        }
    }

    /// Plain clicked links stay in the panel (Steam) or go to the browser. Everything else (window.open,
    /// form posts, about:blank written by script) gets a real child view, so POST bodies and
    /// window.opener keep working for checkout and payment providers.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        if let url, url.scheme?.lowercased() == "steam" {
            follow(SteamLink(url), from: action)
            return nil
        }
        if let url, SteamLink.isWeb(url), action.navigationType == .linkActivated, action.request.httpMethod ?? "GET" == "GET" {
            if SteamLink.isSteamWeb(url) { self.webView.load(action.request) } else { NSWorkspace.shared.open(url) }
            return nil
        }
        guard url.map({ SteamLink.isWeb($0) || $0.absoluteString.isEmpty || $0.absoluteString == "about:blank" }) ?? true else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.customUserAgent = SteamWebSession.browserAgent
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
    func closePopup(_ id: ObjectIdentifier?) {
        guard let id, let i = popups.firstIndex(where: { $0.id == id }) else { return }
        for p in popups[i...] {
            p.webView.stopLoading()
            popupObservers[p.id] = nil
        }
        popups.removeSubrange(i...)
    }

    /// steam:// links act only when a Steam page asked; an ad or third-party iframe cannot start games.
    private func follow(_ link: SteamLink, from action: WKNavigationAction) {
        let source = action.sourceFrame.securityOrigin
        guard let origin = URL(string: "\(source.protocol)://\(source.host)/"), SteamLink.isSteamWeb(origin) else { return }
        switch link {
        case let .play(id), let .install(id): onSteamApp(id)
        case let .page(u): webView.load(URLRequest(url: u))
        case let .external(u): NSWorkspace.shared.open(u)
        case .ignore: break
        }
    }

    /// No web header or footer (the panel's bar replaces them), no "Install Steam".
    static let chromeScript = """
    (() => {
      if (!/(^|\\.)(steampowered\\.com|steamcommunity\\.com)$/.test(location.hostname)) return;
      const css = `#global_header, .responsive_header, #footer, #footer_spacer, #footer_responsive_optin_spacer,
        .header_installsteam_btn, a.btn_install_steam { display: none !important; }
        .responsive_page_frame { padding-top: 0 !important; }
        .responsive_page_content { padding-top: 0 !important; }`;
      const s = document.createElement('style'); s.id = 'vapor_chrome'; s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    })();
    """
}

/// Slides over the content area (not the sidebar), leaving a thin dimmed margin.
struct WebPanel: View {
    @ObservedObject var model: WebPanelModel

    var body: some View {
        ZStack {
            if model.isOpen {
                Color.black.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                    .transition(.opacity)
                panel.transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            bar
            ZStack(alignment: .top) {
                WebViewHost(webView: model.webView)
                if model.loading {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent).frame(width: g.size.width * max(0.08, model.progress), height: 2)
                    }
                    .frame(height: 2)
                    .animation(.easeOut(duration: 0.2), value: model.progress)
                }
                if let popup = model.popups.last {
                    PopupLayer(popup: popup) { model.closePopup(popup.id) }.id(popup.id)
                }
            }
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.leading, 28).padding(.trailing, 14).padding(.vertical, 14)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            button("chevron.left", help: String(localized: "后退"), enabled: model.canGoBack) { model.webView.goBack() }
            button("chevron.right", help: String(localized: "前进"), enabled: model.canGoForward) { model.webView.goForward() }
            button(model.loading ? "xmark" : "arrow.clockwise", help: model.loading ? String(localized: "停止") : String(localized: "重新载入"), enabled: true) {
                if model.loading { model.webView.stopLoading() } else { _ = model.webView.reload() }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(model.url?.host ?? "").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .padding(.leading, 10)
            Spacer(minLength: 12)
            Button(String(localized: "在浏览器中打开")) { model.openInBrowser() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                .padding(.trailing, 6)
            Button { model.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text)
            .keyboardShortcut(model.popups.isEmpty ? .cancelAction : nil)
            .help(String(localized: "关闭"))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func button(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text : Theme.tertiary)
        .disabled(!enabled)
        .help(help)
    }
}

/// A popup page (payment provider, 3-D Secure, sign-in) over the panel.
private struct PopupLayer: View {
    let popup: WebPanelModel.Popup
    var close: () -> Void

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
                        .buttonStyle(.plain).foregroundStyle(Theme.text)
                        .keyboardShortcut(.cancelAction)
                        .help(String(localized: "关闭"))
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
