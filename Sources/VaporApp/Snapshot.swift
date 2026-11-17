import AppKit
import SwiftUI
import VaporKit

/// Renders whole screens (sidebar, toolbar and all) to PNG. The window is fully
/// transparent, ignores the mouse and the app never activates, so nothing appears.
@MainActor
enum Snapshot {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let (installs, games) = LibraryStore.scan()
        for g in games {   // warm the artwork cache so the first frame is complete
            for kind in [Artwork.Kind.cover, .hero, .logo] {
                _ = ArtworkLoader.shared.imageNow(appid: g.appid, kind: kind, installs: installs)
            }
        }
        let state = AppState()
        state.store.installs = installs
        state.store.games = games

        capture(state, to: dir.appendingPathComponent("library.png"))
        if let game = games.first(where: { $0.profile != nil }) {
            state.selectedID = game.appid
            capture(state, to: dir.appendingPathComponent("detail.png"))
            state.selectedID = nil
        } else {
            skip("detail.png", "no installed game has a profile")
        }
        if let game = games.first(where: { !$0.installed && $0.windowsOnly }) {
            state.selectedID = game.appid
            capture(state, to: dir.appendingPathComponent("detail-install.png"))
            state.selectedID = nil
        } else {
            skip("detail-install.png", "no owned Windows game is uninstalled")
        }
        func spin(_ seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline && !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        // The library push proves the channel works; uiOnline alone can be reset by the engine's poll
        // while Windows Steam is signed out, so it is re-forced before each capture that reads Steam.
        Task { await state.engine.forceUIOnlineForSnapshot() }
        spin(12) { !state.engine.steamApps.isEmpty }
        let online = !state.engine.steamApps.isEmpty
        func ensureOnline() {
            guard !state.engine.uiOnline else { return }
            Task { await state.engine.forceUIOnlineForSnapshot() }
            spin(5) { state.engine.uiOnline }
        }
        let offline = "Steam's UI runtime did not answer within 12 s"
        if online {
            ensureOnline()
            capture(state, to: dir.appendingPathComponent("properties.png"), size: NSSize(width: 760, height: 520),
                    root: AnyView(PropertiesSheet(appid: 976310) {}.environmentObject(state.engine)))
        } else {
            skip("properties.png", offline)
        }
        state.destination = .friends
        capture(state, to: dir.appendingPathComponent("friends.png"))
        if online, let portal = state.store.games.first(where: { $0.appid == 620 }) {
            state.destination = .all
            state.selectedID = portal.appid
            capture(state, to: dir.appendingPathComponent("detail-achievements.png"), size: NSSize(width: 1320, height: 1500))
            state.selectedID = nil
        }
        state.destination = .downloads
        capture(state, to: dir.appendingPathComponent("downloads.png"))
        if online { captureEulaStep(state, to: dir.appendingPathComponent("install-eula.png")) } else { skip("install-eula.png", offline) }
        // The store front keeps what it fetched in StoreData, so load it first and the capture shows it.
        state.destination = .store
        if online { ensureOnline() }
        var storeLoaded = false
        Task { await StoreData.shared.loadHome(state.engine); storeLoaded = true }
        spin(45) { storeLoaded && !StoreData.shared.homeLoading }
        capture(state, to: dir.appendingPathComponent("store.png"))
        state.destination = .community
        capture(state, to: dir.appendingPathComponent("community.png"))
        RunLoop.current.run(until: Date().addingTimeInterval(15))
        capture(state, to: dir.appendingPathComponent("community.png"))
        // The game page again, now that Steam's UI answers. GamePageModel keeps each app's content, so
        // loading it once here makes the page's own model start from it.
        if online, let game = games.first(where: { $0.profile != nil }) {
            var pageLoaded = false
            Task { await GamePageModel().load(game.appid, engine: state.engine); pageLoaded = true }
            spin(40) { pageLoaded }
            state.destination = .all
            state.selectedID = game.appid
            capture(state, to: dir.appendingPathComponent("detail.png"))
            state.selectedID = nil
        }
        // Native pages load in the view's task; fetch first so the capture shows the page, not its skeleton.
        for (name, appid) in [("storepage-owned.png", UInt32(730)), ("storepage.png", UInt32(1091500))] {
            var page: StorePage??
            Task { page = .some(await StorePageCache.shared.page(appid)) }
            spin(25) { page != nil }
            guard page??.name != nil else { skip(name, "the store page for \(appid) did not load"); continue }
            state.pages = [.store(appid)]
            capture(state, to: dir.appendingPathComponent(name), size: NSSize(width: 1320, height: 1100))
        }
        state.pages = []
        capture(state, to: dir.appendingPathComponent("onboarding.png"),
                root: AnyView(OnboardingView(model: OnboardingModel(persist: false)) {}.background(Theme.background)))
        state.destination = .runtimes
        var scanned = false
        Task { await RuntimesModel.shared.load(); scanned = true }
        spin(20) { scanned }
        capture(state, to: dir.appendingPathComponent("runtimes.png"))
        state.destination = .settings
        capture(state, to: dir.appendingPathComponent("settings.png"))
        if online {
            // SettingsView reads Steam's settings when it appears; check they can be read so the capture shows them.
            ensureOnline()
            var read: Bool?
            Task { read = (try? await state.engine.ui.settings()) != nil }
            spin(10) { read != nil }
            if read == true {
                capture(state, to: dir.appendingPathComponent("settings-steam.png"), size: NSSize(width: 1320, height: 1400))
            } else {
                skip("settings-steam.png", read == nil ? "Steam's settings did not load within 10 s" : "Steam's settings could not be read")
            }
        } else {
            skip("settings-steam.png", offline)
        }
    }

    static func skip(_ name: String, _ reason: String) {
        print("skipped \(name): \(reason)")
    }

    /// The install wizard's agreement step, with a real EULA fetched the way the agent does (no wizard).
    static func captureEulaStep(_ state: AppState, to url: URL) {
        var data: Data?
        let js = """
        const e = (await SteamClient.Apps.LoadEula(714010))[0];
        const u = new URL(e.url.replace('http://', 'https://')); u.searchParams.append('eulaLang', 'schinese'); u.searchParams.append('json', '1');
        const d = await (await fetch(u, { credentials: 'include' })).json();
        return { appid: 714010, state: 8, required: 22529243614, available: 188000000000, error: 0, step: 'eula', problem: null, done: false,
                 eulas: [{ id: String(e.id), url: e.url, version: Number(e.version), title: d.title ?? null, content: d.content ?? null }], keys: null };
        """
        Task { data = try? await state.engine.ui.evaluate(js) }
        let deadline = Date().addingTimeInterval(15)
        while data == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        guard let data, let run = try? JSONDecoder().decode(SteamUI.Install.self, from: data) else {
            skip(url.lastPathComponent, data == nil ? "the EULA did not load within 15 s" : "the EULA step could not be decoded")
            return
        }
        capture(state, to: url, size: NSSize(width: 620, height: 560),
                root: AnyView(InstallFlowSheet(run: run).environmentObject(state.engine).background(Theme.background)))
    }

    static func capture(_ state: AppState, to url: URL, size: NSSize = NSSize(width: 1320, height: 860),
                        root: AnyView? = nil) {
        // Borderless windows are not pulled back on-screen, so this one renders fully
        // (opaque, so SwiftUI draws) while sitting outside every display.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        let host = NSHostingView(rootView: root ?? AnyView(RootView(state: state)))
        host.wantsLayer = true
        window.contentView = host
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        let scale = window.backingScaleFactor
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let layer = host.layer,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)      // AppKit-hosted layers are flipped
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        window.orderOut(nil)
        window.close()
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("wrote \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
}
