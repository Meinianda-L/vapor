import SwiftUI
import VaporKit

struct CommunityHubView: View {
    let appid: UInt32
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    @State private var tab: CommunityTab
    @State private var detail: CommunityDetail?
    @State private var hub: CommunityHub?

    init(appid: UInt32, tab: CommunityTab = .all, open: @escaping (URL) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.appid = appid; self.open = open; self.onClose = onClose
        _tab = State(initialValue: tab)
    }

    var body: some View {
        CommunityFrame(title: detail == nil ? (hub?.appName.isEmpty == false ? String(localized: "\(hub!.appName) 社区") : String(localized: "社区")) : nil,
                       back: detail == nil ? String(localized: "返回") : tab.title, open: open,
                       onBack: { if detail == nil { onClose() } else { detail = nil } }) {
            if let detail {
                CommunityDetailHost(appid: appid, detail: detail, open: open, subscribe: nil)
            } else {
                if let hub, hub.tabs.count > 1 {
                    TextTabs(items: hub.tabs.map { ($0, $0.title) }, selection: $tab)
                }
                content
            }
        }
        .task(id: appid) {
            let url = CommunityClient.hub(appid), id = appid
            if let html = try? await Task.detached(operation: { try await CommunityClient.fetchString(url) }).value {
                hub = await Task.detached { CommunityParsers.hub(html: html, appid: id) }.value
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .all: HubOverview(appid: appid, switchTo: { tab = $0 }, select: { detail = $0 })
        case .discussions: DiscussionsList(appid: appid) { detail = $0 }
        case .guides: SharedFileBrowser(appid: appid, kind: .guides) { detail = $0 }
        case .workshop: SharedFileBrowser(appid: appid, kind: .workshop) { detail = $0 }
        case .screenshots: MediaGrid(appid: appid, segment: "screenshots") { detail = $0 }.id(tab)
        case .artwork: MediaGrid(appid: appid, segment: "images") { detail = $0 }.id(tab)
        }
    }
}

private struct HubOverview: View {
    let appid: UInt32
    let switchTo: (CommunityTab) -> Void
    let select: (CommunityDetail) -> Void

    var body: some View {
        Loadable(id: appid, rows: 8, load: loader) { hub in
            let cards = hub.cards
            VStack(alignment: .leading, spacing: 34) {
                let topics = cards.filter { $0.kind == .discussion }
                if !topics.isEmpty {
                    section(String(localized: "讨论"), .discussions) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(topics.prefix(8).enumerated()), id: \.element.id) { i, c in
                                if i > 0 { Divider().overlay(Theme.hairline) }
                                Button { select(.thread(c.url)) } label: { topicRow(c) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                let guides = cards.filter { $0.kind == .guide }
                if !guides.isEmpty {
                    section(String(localized: "指南"), .guides) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(guides.prefix(5).enumerated()), id: \.element.id) { i, c in
                                if i > 0 { Divider().overlay(Theme.hairline) }
                                Button { if let id = c.fileID { select(.file(id)) } } label: { guideRow(c) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                grid(String(localized: "创意工坊"), .workshop, cards.filter { $0.kind == .workshop })
                grid(String(localized: "截图"), .screenshots, cards.filter { $0.kind == .screenshot })
                grid(String(localized: "艺术作品"), .artwork, cards.filter { $0.kind == .artwork })
                if cards.allSatisfy({ $0.kind == .news }) { CommunityNote(text: String(localized: "社区暂时没有内容。")) }
            }
        }
    }

    private var loader: @Sendable () async throws -> CommunityHub {
        let url = CommunityClient.hub(appid), id = appid
        return { CommunityParsers.hub(html: try await CommunityClient.fetchString(url), appid: id) }
    }

    private func section<C: View>(_ title: String, _ tab: CommunityTab, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Button("查看全部") { switchTo(tab) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            body()
        }
    }

    @ViewBuilder private func grid(_ title: String, _ tab: CommunityTab, _ cards: [CommunityCard]) -> some View {
        if !cards.isEmpty {
            section(title, tab) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(cards.prefix(8)) { c in
                        Button { if let id = c.fileID { select(.file(id)) } } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CommunityThumb(url: c.image)
                                MetaLine(parts: [c.title, c.author], size: 11.5)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func topicRow(_ c: CommunityCard) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if !c.excerpt.isEmpty { Text(c.excerpt).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            MetaLine(parts: [c.author, c.comments.map { String(localized: "\($0) 回复") } ?? ""], size: 11.5)
        }
        .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func guideRow(_ c: CommunityCard) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CommunityThumb(url: c.image, aspect: 1).frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                MetaLine(parts: [c.author], size: 11.5)
                if !c.excerpt.isEmpty { Text(c.excerpt).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
