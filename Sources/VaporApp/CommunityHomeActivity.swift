import SwiftUI
import VaporKit

/// 动态: what friends did lately, from the signed-in web session.
struct CommunityActivityTab: View {
    var open: (URL) -> Void
    var openApp: (UInt32) -> Void
    @EnvironmentObject private var engine: EngineModel

    var body: some View {
        if let id = engine.account?.steamID {
            Loadable(id: id, rows: 8, load: loader(id)) { events in
                if events.isEmpty {
                    CommunityNote(text: String(localized: "还没有好友动态。"))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                            if i == 0 || events[i - 1].day != e.day {
                                if !e.day.isEmpty { SectionLabel(text: e.day).padding(.top, i == 0 ? 0 : 22).padding(.bottom, 6) }
                            } else { Divider().overlay(Theme.hairline) }
                            row(e)
                        }
                    }
                }
            }
        } else {
            CommunityNote(text: String(localized: "登录 Steam 后可以看到好友动态。"))
        }
    }

    private func loader(_ id: String) -> @Sendable () async throws -> [ActivityEvent] {
        let url = CommunityHomeClient.activity(steamID: id)
        return {
            guard let cookie = await CommunitySession.cookieHeader() else { throw URLError(.userAuthenticationRequired) }
            return BlotterParser.events(html: try await CommunityClient.fetchString(url, cookie: cookie, ttl: 120))
        }
    }

    private func row(_ e: ActivityEvent) -> some View {
        Button { if let l = e.link { open(l) } else if let a = e.appid { openApp(a) } } label: {
            HStack(alignment: .top, spacing: 12) {
                CommunityAvatar(url: e.avatar, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    if !e.author.isEmpty { Text(e.author).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text) }
                    if !e.text.isEmpty { Text(e.text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(3).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 12)
                if e.image != nil { CommunityThumb(url: e.image, aspect: 16.0 / 9).frame(width: 120) }
            }
            .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
