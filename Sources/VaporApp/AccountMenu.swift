import SwiftUI
import VaporKit

/// Sidebar footer: the signed-in account and the headless Windows Steam client behind it.
struct AccountMenu: View {
    @EnvironmentObject var engine: EngineModel
    let openProfile: (String) -> Void
    let openAccount: () -> Void
    @State private var hovering = false

    /// The persona state only means something while the client is up and logged on.
    private var account: SteamUI.Account? { engine.uiOnline ? engine.account : nil }

    // The avatar sits outside the Menu: AppKit renders a menu button's label as a template image, which
    // turns a photo into a placeholder glyph.
    var body: some View {
        HStack(spacing: 10) {
            AccountAvatar(url: account?.avatar, name: account?.persona ?? "")
                .onTapGesture { if let account { openProfile(account.steamID) } }
                .help(engine.strings("UserManagement_ViewProfile") ?? "查看个人资料")
            menu
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.white.opacity(0.05) : .clear))
        .padding(.horizontal, 10)
        .onHover { hovering = $0 }
    }

    private var menu: some View {
        Menu {
            Picker("状态", selection: Binding(get: { account?.personaState ?? 0 }, set: { engine.setPersonaState($0) })) {
                ForEach(Self.states, id: \.value) { s in Text(engine.strings(s.key) ?? s.fallback).tag(s.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(account == nil)
            Divider()
            if let account {
                Button(engine.strings("UserManagement_ViewProfile") ?? "查看个人资料") { openProfile(account.steamID) }
                Button(engine.strings("UserManagement_AccountDetails") ?? "账户详情", action: openAccount)
                Divider()
            }
            if engine.sessionReplaced {
                Text(engine.nativeSteamRunning ? "Mac 版 Steam 登录了同一账号" : "账号在其他设备上登录")
            }
            if let title = engine.controlTitle {
                Button(title) { engine.toggleSteam() }.disabled(engine.busy)
            }
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.map { $0.persona.isEmpty ? $0.accountName : $0.persona } ?? "Steam")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        StatusDot(color: statusColor)
                        Text(statusLine).lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private static let states: [(value: Int, key: String, fallback: String)] = [
        (1, "Menu_Status_Online", "在线"), (3, "Menu_Status_Away", "离开"),
        (7, "Menu_Status_Invisible", "隐身"), (0, "Menu_Status_Offline", "离线"),
    ]

    private var statusLine: String {
        guard let account else { return engine.statusText }
        return Self.states.first { $0.value == account.personaState }.map { engine.strings($0.key) ?? $0.fallback } ?? engine.statusText
    }

    private var statusColor: Color {
        switch account?.personaState {
        case 1: return Theme.ok
        case 3: return Theme.warn
        case 0, 7: return Theme.tertiary
        default: return engine.statusColor
        }
    }
}

extension EngineModel {
    /// What the start/stop control should say, or nil when there is nothing to start (no Windows Steam found).
    var controlTitle: String? {
        if sessionReplaced { return nativeSteamRunning ? "退出 Mac 版 Steam 并重新上线" : "重新上线" }
        guard steam != nil else { return nil }
        if isOnline || connection == .starting { return "停止 Windows Steam" }
        return connection == .needsLogin ? "登录 Windows Steam" : "启动 Windows Steam"
    }

    func toggleSteam() {
        if sessionReplaced { reclaimSession() } else if isOnline || connection == .starting { stop() } else { start() }
    }
}

private struct AccountAvatar: View {
    let url: URL?
    let name: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.surface
                Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .task(id: url) {
            guard let url else { image = nil; return }
            image = AccountAvatarCache.shared.cached(url)
            guard image == nil else { return }
            for attempt in 0..<3 {
                if let img = await AccountAvatarCache.shared.load(url) { image = img; return }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 5))
            }
        }
    }
}

/// One fetch per address and run, off the main thread; failures are not cached.
@MainActor
private final class AccountAvatarCache {
    static let shared = AccountAvatarCache()
    private let images = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return nil }
        images.setObject(img, forKey: url as NSURL)
        return img
    }
}
