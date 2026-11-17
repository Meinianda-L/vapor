import AppKit
import UserNotifications
import VaporKit

/// What Mac Steam shows outside its window while it downloads: a progress bar on the Dock icon and a
/// notification when a game is ready.
@MainActor
final class DownloadSignals {
    private let tile = NSApp.dockTile
    private var bar: DockProgressView?
    private var finished: Set<UInt32> = []
    private var primed = false

    /// Called with every pushed download state.
    func update(downloads: [SteamUI.Download], overview: SteamUI.Overview?, paused: Bool, names: (UInt32) -> String) {
        showProgress(downloads: downloads, overview: overview, paused: paused)
        let done = Set(downloads.filter(\.completed).map(\.appid))
        // The first push lists downloads that finished before Vapor started; only announce new ones.
        if primed { for appid in done.subtracting(finished) { notify(names(appid)) } }
        finished = done
        primed = true
    }

    private func showProgress(downloads: [SteamUI.Download], overview: SteamUI.Overview?, paused: Bool) {
        let active = downloads.first { $0.appid == overview?.appid && !$0.completed } ?? downloads.first { $0.active && !$0.completed }
        guard let active, !paused, !active.paused else {
            if bar != nil { bar = nil; tile.contentView = nil; tile.display() }
            return
        }
        var fraction = active.total > 0 ? Double(active.downloaded) / Double(active.total) : 0
        if fraction == 0, let o = overview, o.appid == active.appid { fraction = o.percent / 100 }
        if bar == nil {
            let view = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            bar = view
            tile.contentView = view
        }
        guard let bar, abs(bar.fraction - fraction) >= 0.002 else { return }
        bar.fraction = min(1, max(0, fraction))
        tile.display()
    }

    private func notify(_ name: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "下载完成")
            content.body = String(localized: "\(name) 已可以开始游戏。")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "download-\(name)", content: content, trigger: nil))
        }
    }
}

/// The app icon with a thin progress bar along its bottom edge, like Finder and Mac Steam.
final class DockProgressView: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let track = NSRect(x: bounds.width * 0.14, y: bounds.height * 0.1, width: bounds.width * 0.72, height: bounds.height * 0.085)
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inset = track.insetBy(dx: 2, dy: 2)
        var fill = inset
        fill.size.width = max(inset.height, inset.width * fraction)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
