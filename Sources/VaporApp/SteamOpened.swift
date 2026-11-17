import Foundation
import UserNotifications
import VaporKit

/// A Steam window or page that opened on its own (steam://open/settings, a game's overlay "view friends", a link that
/// navigates Steam's main window). Steam's window never shows; `kind` says which Vapor page replaces it.
struct SteamOpened: Equatable, Identifiable {
    let id: Int
    let kind: SteamUI.HiddenWindow.Kind
    /// The web page for a store or other web destination.
    let url: URL?
}

/// Steam's overlay notifications (a friend came online, an achievement unlocked …) as macOS notifications. Steam's own
/// toast window is kept hidden by the agent.
@MainActor
final class SteamToasts {
    private var seen: Set<String> = []
    private var primed = false

    func update(_ toasts: [SteamUI.Toast], say: (SteamUI.Dialog.Text?) -> String, appName: (UInt32) -> String?) {
        // The first push lists toasts from before Vapor started.
        defer { seen.formUnion(toasts.map(\.id)); primed = true }
        guard primed else { return }
        for toast in toasts where !seen.contains(toast.id) {
            // "Download Complete" is announced by DownloadSignals already.
            if toast.lines.contains(where: { $0.key == "Notification_DownloadComplete_Title" }) { continue }
            let lines = toast.lines.map { say($0) }.filter { !$0.isEmpty }
            guard let title = lines.first else { continue }
            Self.post(title: title, body: lines.dropFirst().joined(separator: " "), subtitle: appName(toast.appid), id: toast.id)
        }
    }

    private static func post(title: String, body: String, subtitle: String?, id: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let subtitle { content.subtitle = subtitle }
            center.add(UNNotificationRequest(identifier: "steam-toast-\(id)", content: content, trigger: nil))
        }
    }
}
