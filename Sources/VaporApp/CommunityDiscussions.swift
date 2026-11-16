import SwiftUI
import VaporKit

private func fetchForum(_ url: URL) async throws -> CommunityParsers.ForumListing {
    CommunityParsers.forum(html: try await CommunityClient.fetchString(url))
}

/// Forum list: sub-forums, topics, paging and search for one app.
struct DiscussionsList: View {
    let appid: UInt32
    let select: (CommunityDetail) -> Void

    private struct Query: Hashable { var forum: URL?; var page = 1; var search = "" }
    @State private var query: Query
    @State private var draft = ""
    @State private var forums: [CommunityParsers.ForumRef] = []
    @State private var gid: String?

    init(appid: UInt32, initialForum: URL? = nil, select: @escaping (CommunityDetail) -> Void) {
        self.appid = appid
        self.select = select
        _query = State(initialValue: Query(forum: initialForum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                TextTabs(items: forums.map { ($0.url, $0.name) }, selection: Binding(
                    get: { query.forum ?? forums.first { $0.selected }?.url ?? forums.first?.url ?? CommunityClient.defaultForum(appid) },
                    set: { query = Query(forum: $0); draft = "" }))
                Spacer(minLength: 0)
                CommunitySearchField(prompt: "搜索讨论", text: $draft) {
                    let q = draft.trimmingCharacters(in: .whitespaces)
                    query = Query(forum: query.forum, page: 1, search: q)
                }
            }
            if !query.search.isEmpty {
                HStack(spacing: 12) {
                    Text("“\(query.search)” 的搜索结果").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    Button("清除") { query.search = ""; query.page = 1; draft = "" }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }
            }
            Loadable(id: query, load: loader(query), onLoad: { listing in
                if !listing.forums.isEmpty {
                    var seen = Set<String>()
                    forums = listing.forums.filter { seen.insert($0.name).inserted }
                }
                gid = listing.gidForum ?? gid
            }) { listing in
                list(listing)
            }
        }
    }

    private func loader(_ q: Query) -> @Sendable () async throws -> CommunityParsers.ForumListing {
        let appid = appid, gid = gid
        return {
            if q.search.isEmpty {
                return try await fetchForum(CommunityClient.forum(q.forum ?? CommunityClient.defaultForum(appid), page: q.page))
            }
            return try await fetchForum(CommunityClient.forumSearch(appid, query: q.search, gidForum: nil, page: q.page))
        }
    }

    @ViewBuilder private func list(_ listing: CommunityParsers.ForumListing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if listing.topics.isEmpty {
                CommunityNote(text: query.search.isEmpty ? "这个论坛还没有主题。" : "没有找到相关讨论。")
            }
            ForEach(Array(listing.topics.enumerated()), id: \.element.id) { index, topic in
                if index > 0 { Divider().overlay(Theme.hairline) }
                Button { select(.thread(topic.url)) } label: { row(topic) }.buttonStyle(.plain)
            }
            if listing.pageCount > 1 {
                CommunityPager(page: listing.page, pageCount: listing.pageCount) { query.page = $0 }
            }
        }
    }

    private func row(_ topic: CommunityParsers.ForumTopic) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if topic.pinned { Text("置顶").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary) }
                    if topic.locked { Text("已锁定").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary) }
                    Text(topic.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                }
                MetaLine(parts: [topic.author, topic.lastPost.map { "最后回复 \(CommunityTime.string($0))" } ?? ""], size: 11.5)
            }
            Spacer(minLength: 12)
            Text("\(topic.replies) 回复").font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One topic with its replies, paged.
struct DiscussionThreadView: View {
    let appid: UInt32
    let url: URL
    var open: (URL) -> Void = { _ in }

    @State private var page = 1

    var body: some View {
        Loadable(id: page, load: loader(page)) { thread in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    MetaLine(parts: [thread.forumName, "\(thread.total) 条回复"], size: 12)
                }
                .padding(.bottom, 18)
                if page == 1, let op = thread.opening { post(op, number: "楼主") }
                ForEach(thread.replies) { reply in post(reply, number: reply.number ?? "") }
                if thread.pageCount > 1 {
                    CommunityPager(page: thread.page, pageCount: thread.pageCount) { page = $0 }.padding(.top, 14)
                }
            }
        }
        .id(url)
    }

    private func loader(_ page: Int) -> @Sendable () async throws -> CommunityParsers.ForumThread {
        let target = CommunityClient.thread(url, page: page)
        return {
            guard let t = CommunityParsers.thread(html: try await CommunityClient.fetchString(target)) else { throw URLError(.cannotParseResponse) }
            return t
        }
    }

    private func post(_ p: CommunityParsers.ForumPost, number: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 12) {
                CommunityAvatar(url: p.avatar, size: 34)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        authorName(p)
                        Text(CommunityTime.string(p.date)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                        Spacer(minLength: 0)
                        Text(number).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    }
                    RichBlocksView(blocks: p.blocks, size: 13.5, maxImage: 560)
                }
            }
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder private func authorName(_ p: CommunityParsers.ForumPost) -> some View {
        if let profile = communityProfile(p.authorURL) {
            Button(p.author) { open(profile) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        } else {
            Text(p.author).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        }
    }
}

struct DiscussionsView: View {
    let appid: UInt32
    private let forum: URL?
    private let open: (URL) -> Void
    private let onClose: () -> Void

    @State private var detail: CommunityDetail?

    init(appid: UInt32, forum: URL? = nil, topic: URL? = nil, open: @escaping (URL) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.appid = appid; self.forum = forum; self.open = open; self.onClose = onClose
        _detail = State(initialValue: topic.map { .thread($0) })
    }

    var body: some View {
        CommunityFrame(title: detail == nil ? "讨论" : nil, back: detail == nil ? "返回" : "讨论列表", open: open,
                       onBack: { if detail == nil { onClose() } else { detail = nil } }) {
            if case .thread(let url) = detail {
                DiscussionThreadView(appid: appid, url: url, open: open)
            } else {
                DiscussionsList(appid: appid, initialForum: forum) { detail = $0 }
            }
        }
    }
}
