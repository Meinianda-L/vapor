import SwiftUI
import VaporKit

/// The comments under a profile, workshop item, guide or screenshot, newest first, with a box to add one.
struct CommentsSection: View {
    let thread: CommentThread
    var open: (URL) -> Void = { _ in }

    private struct Key: Hashable { var page = 1; var refresh = 0 }
    @State private var key = Key()
    @State private var draft = ""
    @State private var posting = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: String(localized: "留言"))
            compose
            Loadable(id: key, rows: 3, load: loader(key.page)) { page in
                VStack(alignment: .leading, spacing: 0) {
                    if page.comments.isEmpty { CommunityNote(text: String(localized: "还没有留言。")) }
                    ForEach(page.comments) { comment in row(comment) }
                    if page.pageCount > 1 {
                        CommunityPager(page: page.page, pageCount: page.pageCount) { key.page = $0 }.padding(.top, 12)
                    }
                }
            }
        }
        .id(thread)
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("添加留言", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2...6)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 14) {
                Button(posting ? String(localized: "正在发表…") : String(localized: "发表")) { Task { await submit() } }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(canPost ? Theme.accent : Theme.tertiary).disabled(!canPost)
                if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.warn) }
            }
        }
    }

    private var canPost: Bool { !posting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        posting = true
        problem = nil
        defer { posting = false }
        guard let cookie = await CommunitySession.cookieHeader() else { problem = String(localized: "网页登录还没有就绪，请稍后再试。"); return }
        do {
            try await CommentClient.post(text, to: thread, cookie: cookie)
            draft = ""
            key = Key(page: 1, refresh: key.refresh + 1)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? String(localized: "没有发表成功，请稍后再试。")
        }
    }

    private func loader(_ page: Int) -> @Sendable () async throws -> CommentPage {
        let t = thread
        return { try await CommentClient.fetch(t, start: (page - 1) * CommentClient.pageSize) }
    }

    private func row(_ c: CommunityComment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 12) {
                CommunityAvatar(url: c.avatar, size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let link = c.authorURL {
                            Button(c.author) { open(link) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        } else {
                            Text(c.author).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        }
                        Text(CommunityTime.string(c.date)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    }
                    RichBlocksView(blocks: c.blocks, size: 13, maxImage: 480)
                }
            }
            .padding(.vertical, 12)
        }
    }
}
