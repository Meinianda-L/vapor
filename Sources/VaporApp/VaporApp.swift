import AppKit
import SwiftUI
import VaporKit

/// Single-window app: quit when the window closes, so `open` always starts fresh. Windows Steam comes
/// up with the app and goes down with it, unless it is still downloading and the user keeps it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        state.engine.startAtLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engine = state.engine
        // A running game still needs Steam for DRM and cloud saves.
        guard engine.steam != nil, engine.running.isEmpty else { return .terminateNow }
        if engine.downloading {
            let alert = NSAlert()
            let name = engine.downloads.first { $0.active && !$0.completed }.flatMap { engine.steamApps[$0.appid]?.name }
            alert.messageText = name.map { "Steam 正在下载 \($0)" } ?? "Steam 正在下载"
            alert.informativeText = "Steam 可以在后台继续下载，下次打开 Vapor 时接着显示进度。"
            alert.addButton(withTitle: "继续在后台下载")
            alert.addButton(withTitle: "停止并退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateNow }
        }
        // Closing the window quits too; then the sidebar's status is gone, so say what the wait is for.
        let panel = sender.windows.contains { $0.isVisible } ? nil : Self.shutdownPanel()
        panel?.orderFrontRegardless()
        sender.dockTile.badgeLabel = "…"
        Task {
            await engine.shutDown()
            panel?.close()
            sender.dockTile.badgeLabel = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func shutdownPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Vapor"
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "正在关闭 Steam…")
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        panel.contentView = stack
        panel.center()
        return panel
    }
}

struct VaporSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Vapor") {
            RootView(state: delegate.state)
                .frame(minWidth: 1080, minHeight: 700)
                .task { await delegate.state.store.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
    }
}

/// Entry point: `--snapshot <dir>` renders the main screens to PNG through an invisible,
/// non-activating window (headless review); otherwise runs the app.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        VaporSwiftUIApp.main()
    }
}
