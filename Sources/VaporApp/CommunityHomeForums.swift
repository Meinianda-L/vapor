import SwiftUI
import VaporKit

/// 讨论: Steam's general forums, listed here and read in place; hubs of single games open natively through `open`.
struct CommunityForumsTab: View {
    var open: (URL) -> Void

    private enum Route: Hashable {
        case forum(URL, String)
        case thread(URL)
    }

    @State private var route: Route?
    @State private var backStack: [Route] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let route {
                Button(action: pop) {
                    Text("‹ \(backTitle)").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                switch route {
                case .forum(let url, let name): ForumTopics(url: url, name: name) { push(.thread($0)) }.id(url)
                case .thread(let url): DiscussionThreadView(appid: 0, url: url, open: open).id(url)
                }
            } else {
                Loadable(id: 0, rows: 8, load: { try await Self.loadIndex() }) { index in
                    VStack(alignment: .leading, spacing: 30) {
                        section(String(localized: "Steam 论坛"), index.forums)
                        section(String(localized: "Steam 功能与社区"), index.groups)
                    }
                }
            }
        }
    }

    private var backTitle: String {
        if case .forum? = backStack.last { return "论坛" }
        return backStack.isEmpty ? String(localized: "讨论") : String(localized: "返回")
    }

    private func push(_ next: Route) {
        if let route { backStack.append(route) }
        route = next
    }

    private func pop() { route = backStack.popLast() }

    private static func loadIndex() async throws -> CommunityHomeParser.DiscussionIndex {
        CommunityHomeParser.discussionIndex(html: try await CommunityClient.fetchString(CommunityHomeClient.discussions, ttl: 600))
    }

    @ViewBuilder private func section(_ title: String, _ rows: [CommunityHomeParser.ForumRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: title)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().overlay(Theme.hairline) }
                        Button { go(row) } label: { forumRow(row) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Forums of a single game have a native hub; the rest are read here.
    private func go(_ row: CommunityHomeParser.ForumRow) {
        if CommunityPage.page(for: row.url) != nil { open(row.url) } else { push(.forum(row.url, row.name)) }
    }

    private func forumRow(_ row: CommunityHomeParser.ForumRow) -> some View {
        HStack(spacing: 12) {
            if row.avatar != nil { CommunityAvatar(url: row.avatar, size: 28) }
            Text(row.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 12)
            if let last = row.lastPost { Text(CommunityTime.string(last)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
            Text(row.topics).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
        }
        .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

/// The topics of one forum, paged.
private struct ForumTopics: View {
    let url: URL
    let name: String
    let select: (URL) -> Void
    @State private var page = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
            Loadable(id: page, rows: 8, load: loader(page)) { listing in
                VStack(alignment: .leading, spacing: 0) {
                    if listing.topics.isEmpty { CommunityNote(text: String(localized: "这个论坛还没有主题。")) }
                    ForEach(Array(listing.topics.enumerated()), id: \.element.id) { i, topic in
                        if i > 0 { Divider().overlay(Theme.hairline) }
                        Button { select(topic.url) } label: { row(topic) }.buttonStyle(.plain)
                    }
                    if listing.pageCount > 1 { CommunityPager(page: listing.page, pageCount: listing.pageCount) { page = $0 } }
                }
            }
        }
    }

    private func loader(_ page: Int) -> @Sendable () async throws -> CommunityParsers.ForumListing {
        let target = CommunityClient.forum(url, page: page)
        return { CommunityParsers.forum(html: try await CommunityClient.fetchString(target)) }
    }

    private func row(_ topic: CommunityParsers.ForumTopic) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if topic.pinned { Text("置顶").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary) }
                    Text(topic.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                }
                MetaLine(parts: [topic.author, topic.lastPost.map { String(localized: "最后回复 \(CommunityTime.string($0))") } ?? ""], size: 11.5)
            }
            Spacer(minLength: 12)
            Text("\(topic.replies) 回复").font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
        }
        .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
