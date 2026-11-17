import SwiftUI
import VaporKit

enum CommunitySection {
    case workshop, guides

    var section: String { self == .workshop ? "readytouseitems" : "guides" }
    var sorts: [(String, String)] {
        self == .workshop
            ? [("trend", String(localized: "热门")), ("mostrecent", String(localized: "最新")), ("lastupdated", String(localized: "最近更新")), ("totaluniquesubscribers", String(localized: "订阅最多"))]
            : [("trend", String(localized: "热门")), ("mostrecent", String(localized: "最新")), ("toprated", String(localized: "评分最高"))]
    }
}

private func starText(_ stars: Int?) -> String { stars.map { String(localized: "\($0) 星") } ?? "" }

private func sizeText(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Workshop items (grid) or guides (rows) with sort, search and paging.
struct SharedFileBrowser: View {
    let appid: UInt32
    let kind: CommunitySection
    let select: (CommunityDetail) -> Void

    private struct Query: Hashable { var sort = "trend"; var page = 1; var search = "" }
    @State private var query = Query()
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                TextTabs(items: kind.sorts, selection: Binding(get: { query.sort }, set: { query.sort = $0; query.page = 1 }))
                Spacer(minLength: 0)
                CommunitySearchField(prompt: kind == .workshop ? String(localized: "搜索创意工坊") : String(localized: "搜索指南"), text: $draft) {
                    query.search = draft.trimmingCharacters(in: .whitespaces); query.page = 1
                }
            }
            Loadable(id: query, load: loader(query)) { listing in
                VStack(alignment: .leading, spacing: 14) {
                    if listing.items.isEmpty { CommunityNote(text: String(localized: "没有找到内容。")) }
                    if kind == .workshop {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                            ForEach(listing.items) { item in
                                Button { select(.file(item.id)) } label: { card(item) }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(listing.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().overlay(Theme.hairline) }
                                Button { select(.file(item.id)) } label: { row(item) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if listing.pageCount > 1 {
                        CommunityPager(page: listing.page, pageCount: listing.pageCount) { query.page = $0 }
                    }
                }
            }
        }
    }

    private func loader(_ q: Query) -> @Sendable () async throws -> WorkshopListing {
        let url = CommunityClient.browse(appid, section: kind.section, sort: q.sort, search: q.search, page: q.page)
        return {
            guard let l = WorkshopParser.listing(html: try await CommunityClient.fetchString(url)) else { throw URLError(.cannotParseResponse) }
            return l
        }
    }

    private func card(_ item: CommunityParsers.SharedFileCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CommunityThumb(url: item.preview)
            Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
            MetaLine(parts: [item.author, starText(item.stars)], size: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func row(_ item: CommunityParsers.SharedFileCard) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CommunityThumb(url: item.preview).frame(width: 112)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                MetaLine(parts: [item.author, starText(item.stars)], size: 11.5)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Screenshots or artwork of an app, newest or most popular first.
struct MediaGrid: View {
    let appid: UInt32
    let segment: String
    let select: (CommunityDetail) -> Void

    private struct Query: Hashable { var recent = false; var page = 1 }
    @State private var query = Query()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextTabs(items: [(false, String(localized: "热门")), (true, String(localized: "最新"))], selection: Binding(get: { query.recent }, set: { query = Query(recent: $0) }))
            Loadable(id: query, load: loader(query)) { cards in
                VStack(alignment: .leading, spacing: 14) {
                    if cards.isEmpty { CommunityNote(text: String(localized: "没有更多内容。")) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                        ForEach(cards) { card in
                            Button { if let id = card.fileID { select(.file(id)) } } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CommunityThumb(url: card.image)
                                    MetaLine(parts: [card.title, card.author], size: 11.5)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    CommunityPager(page: query.page, hasNext: cards.count >= 10) { query.page = $0 }
                }
            }
        }
    }

    private func loader(_ q: Query) -> @Sendable () async throws -> [CommunityCard] {
        let url = CommunityClient.media(appid, segment: segment, recent: q.recent, page: q.page)
        return { CommunityParsers.cards(html: try await CommunityClient.fetchString(url)) }
    }
}

/// An item, guide, screenshot or artwork.
struct SharedFileDetailView: View {
    let id: UInt64
    var open: (URL) -> Void = { _ in }
    /// Replaces the native subscribe; by default the client's own workshop subscription is used.
    var subscribe: ((UInt64) -> Void)?

    @EnvironmentObject private var engine: EngineModel
    @State private var section: String?
    @State private var subscribed: Bool?
    @State private var working = false
    @State private var confirmUnsubscribe = false

    var body: some View {
        Loadable(id: id, load: loader) { file in
            VStack(alignment: .leading, spacing: 20) {
                header(file)
                switch file.kind {
                case .guide: guide(file)
                default: body(file)
                }
                if let thread = file.commentThread { CommentsSection(thread: thread, open: open).padding(.top, 8) }
            }
        }
        .id(id)
    }

    private var loader: @Sendable () async throws -> CommunityParsers.SharedFile {
        let url = CommunityClient.file(id)
        return {
            guard let f = CommunityParsers.sharedFile(html: try await CommunityClient.fetchString(url)) else { throw URLError(.cannotParseResponse) }
            return f
        }
    }

    private func header(_ file: CommunityParsers.SharedFile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(file.title.isEmpty ? String(localized: "截图") : file.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                MetaLine(parts: [file.coAuthors.isEmpty ? file.author : file.coAuthors, starText(file.stars), file.ratingNote], size: 12)
            }
            Spacer(minLength: 0)
            if file.kind == .item, let appid = file.appid { subscribeButton(appid) }
        }
    }

    private func subscribeButton(_ appid: UInt32) -> some View {
        let on = subscribed == true
        return Button(working ? "请稍候…" : on ? String(localized: "已订阅") : "订阅") {
            if let subscribe { subscribe(id) } else if on { confirmUnsubscribe = true } else { Task { await setSubscribed(true, appid) } }
        }
        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Theme.secondary : Theme.text)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline))
        .disabled(working || (subscribe == nil && (subscribed == nil || !engine.uiOnline)))
        .confirmationDialog("取消订阅这个创意工坊物品？", isPresented: $confirmUnsubscribe) {
            Button("取消订阅", role: .destructive) { Task { await setSubscribed(false, appid) } }
        }
        .task(id: id) {
            guard subscribe == nil, engine.uiOnline else { return }
            let ui = engine.ui, item = id
            let found = try? await ui.subscribedWorkshopItems(appid: appid, ids: [item])
            if !Task.isCancelled { subscribed = found.map { $0.contains(item) } }
        }
    }

    private func setSubscribed(_ on: Bool, _ appid: UInt32) async {
        working = true
        defer { working = false }
        if (try? await engine.ui.setWorkshopSubscription(id, appid: appid, subscribed: on)) != nil { subscribed = on }
    }

    private func stats(_ file: CommunityParsers.SharedFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(file.stats.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.label).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Text(s.value).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }
            }
            if !file.tags.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("标签").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Text(file.tags.joined(separator: "、")).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }
            }
        }
        .frame(width: 200, alignment: .leading)
    }

    private func body(_ file: CommunityParsers.SharedFile) -> some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(file.images.enumerated()), id: \.offset) { _, u in CommunityPicture(url: u, maxWidth: 640) }
                RichBlocksView(blocks: file.description)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stats(file)
        }
    }

    private func guide(_ file: CommunityParsers.SharedFile) -> some View {
        let current = file.sections.first { $0.id == section }
        return HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: String(localized: "目录")).padding(.bottom, 6)
                tocRow(String(localized: "总览"), on: current == nil) { section = nil }
                ForEach(file.sections) { s in tocRow(s.title, on: s.id == current?.id) { section = s.id } }
                Divider().overlay(Theme.hairline).padding(.vertical, 12)
                stats(file)
            }
            .frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) {
                if let current {
                    Text(current.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    RichBlocksView(blocks: current.blocks)
                } else {
                    RichBlocksView(blocks: file.description)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tocRow(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(on ? Theme.accent : Theme.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Detail host shared by every page that lists shared files.
struct CommunityDetailHost: View {
    let appid: UInt32
    let detail: CommunityDetail
    var open: (URL) -> Void
    var subscribe: ((UInt64) -> Void)?

    var body: some View {
        switch detail {
        case .thread(let url): DiscussionThreadView(appid: appid, url: url, open: open)
        case .file(let id): SharedFileDetailView(id: id, open: open, subscribe: subscribe)
        }
    }
}

struct GuidesView: View {
    let appid: UInt32
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    @State private var detail: CommunityDetail?

    var body: some View {
        CommunityFrame(title: detail == nil ? String(localized: "指南") : nil, back: detail == nil ? String(localized: "返回") : String(localized: "指南列表"), open: open,
                       onBack: { if detail == nil { onClose() } else { detail = nil } }) {
            if let detail { CommunityDetailHost(appid: appid, detail: detail, open: open, subscribe: nil) }
            else { SharedFileBrowser(appid: appid, kind: .guides) { detail = $0 } }
        }
    }
}

struct WorkshopView: View {
    let appid: UInt32
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Called with the item id; by default the item's steam:// page is opened through `open`.
    var subscribe: ((UInt64) -> Void)?
    @State private var detail: CommunityDetail?

    var body: some View {
        CommunityFrame(title: detail == nil ? String(localized: "创意工坊") : nil, back: detail == nil ? String(localized: "返回") : String(localized: "创意工坊"), open: open,
                       onBack: { if detail == nil { onClose() } else { detail = nil } }) {
            if let detail { CommunityDetailHost(appid: appid, detail: detail, open: open, subscribe: subscribe) }
            else { SharedFileBrowser(appid: appid, kind: .workshop) { detail = $0 } }
        }
    }
}

/// A single shared file opened from a link.
struct SharedFileView: View {
    let id: UInt64
    var open: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    var subscribe: ((UInt64) -> Void)?

    var body: some View {
        CommunityFrame(title: nil, open: open, onBack: onClose) { SharedFileDetailView(id: id, open: open, subscribe: subscribe) }
    }
}
