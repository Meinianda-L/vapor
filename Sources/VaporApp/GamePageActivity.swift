import SwiftUI
import VaporKit

/// The left column of Steam's app page (动态): your review prompt, then the activity feed by day —
/// the developer's events, your unlocks and first play, friends' posts. Without Steam's feed (offline,
/// or it never answered) the public news feed stands in.
struct ActivityFeed: View {
    let game: GameItem
    @ObservedObject var page: GamePageModel
    let open: (URL) -> Void
    @EnvironmentObject var engine: EngineModel
    @EnvironmentObject var app: AppState

    private var content: GamePageModel.Content { page.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let review = content.review { ReviewCard(game: game, state: review, minutes: playtime, page: page) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(engine.strings("AppDetails_SectionTitle_Activity") ?? String(localized: "动态"))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    LinkText(title: engine.strings("AppDetails_ViewAllUpdates") ?? String(localized: "查看所有更新")) { app.show(.news(game.appid)) }
                }
                .padding(.bottom, 10)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                feed.padding(.top, 14)
            }
        }
    }

    private var playtime: Int { max(engine.steamApps[game.appid]?.minutesPlayed ?? 0, content.info?.playtimeMinutes ?? 0) }

    @ViewBuilder private var feed: some View {
        if let items = content.activity?.filter({ $0.kind != .other }) {
            if items.isEmpty {
                Text(engine.strings("AppActivity_NoActivity") ?? String(localized: "此游戏的开发者或您的好友最近没有动态。"))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Self.days(items), id: \.day) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(GamePage.relative(group.day)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                            ForEach(group.items) { item in ActivityRow(item: item, game: game, open: open) }
                        }
                    }
                }
            }
        } else if page.settled || !engine.uiOnline {
            NewsSection(appid: game.appid) { app.show(.news(game.appid)) }
        } else {
            Text("正在载入动态…").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
        }
    }

    /// Steam's feed is grouped by calendar day, newest first.
    static func days(_ items: [SteamUI.AppActivity]) -> [(day: Date, items: [SteamUI.AppActivity])] {
        let cal = Calendar.current
        var out: [(day: Date, items: [SteamUI.AppActivity])] = []
        for item in items.sorted(by: { $0.time > $1.time }) {
            let day = cal.startOfDay(for: item.time)
            if out.last?.day == day { out[out.count - 1].items.append(item) } else { out.append((day, [item])) }
        }
        return out
    }
}

private struct ActivityRow: View {
    let item: SteamUI.AppActivity
    let game: GameItem
    let open: (URL) -> Void
    @EnvironmentObject var engine: EngineModel

    private func t(_ key: String, _ args: String...) -> String {
        (engine.strings.text(key, args) ?? "").trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        switch item.kind {
        case .event: if let e = item.event { EventCard(event: e, appid: game.appid, open: open) }
        default: person
        }
    }

    private var line: String {
        switch item.kind {
        case .achievement: return t("AppActivity_Achieved")
        case .firstPlayed: return t("AppActivity_PlayedGameFirstTime", game.name)
        case .status: return t("AppActivity_UserStatus")
        case .review: return t("AppActivity_RecommendedGame")
        case .receivedGame: return item.count > 1 ? t("AppActivity_ReceivedNewGame_Plural", "\(item.count)") : t("AppActivity_ReceivedNewGameList", game.name)
        case .cards: return item.count == 1 ? t("AppActivity_SteamTradingCards_EarnedTradingCard") : t("AppActivity_SteamTradingCards_EarnedTradingCards")
        case .event, .other: return ""
        }
    }

    private var person: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: item.actor?.avatar, name: item.actor?.name ?? "?")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text(item.actor?.name ?? "").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(" " + line).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 8)
                    Text(item.time.formatted(Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current))).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
                if item.kind == .status, !item.text.isEmpty {
                    Text(item.text).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                if item.kind == .review, let up = item.votedUp {
                    Label(t(up ? "AppDetails_Review_Recommended" : "AppDetails_Review_NotRecommended"), systemImage: up ? "hand.thumbsup" : "hand.thumbsdown")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                if !item.unlocks.isEmpty { unlocks }
            }
        }
    }

    @ViewBuilder private var unlocks: some View {
        if item.unlocks.count <= 2 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(item.unlocks.enumerated()), id: \.offset) { _, u in
                    HStack(spacing: 10) {
                        AchievementIcon(url: u.icon, locked: false, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                            if !u.description.isEmpty { Text(u.description).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(2) }
                        }
                    }
                }
            }
        } else {
            let shown = item.unlocks.prefix(10)
            HStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, u in AchievementIcon(url: u.icon, locked: false, size: 40).help(u.name) }
                if item.unlocks.count > shown.count {
                    Text(t("AppActivity_Achieved_PlusMore", "\(item.unlocks.count - shown.count)")).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// A partner event as the library feed draws it: picture (when the event has one), Steam's type
/// label, title, the first lines of the post.
private struct EventCard: View {
    let event: SteamUI.AppActivity.Event
    let appid: UInt32
    let open: (URL) -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: "https://store.steampowered.com/news/app/\(appid)/view/\(event.gid)") { open(url) }
        } label: {
            HStack(alignment: .top, spacing: 16) {
                if let image = event.image {
                    StoreImage(url: image, corner: 4).frame(width: 200, height: 112)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(engine.strings("PartnerEvent_\(event.type)") ?? engine.strings("PartnerEvent_Other") ?? String(localized: "活动"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Text(event.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    if !event.summary.isEmpty {
                        Text(Self.clean(event.summary)).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.white.opacity(0.06) : Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Summaries come from BBCode with the tags already stripped, leaving escaped brackets behind.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")
    }
}

// MARK: - Review

/// Steam's "write a review" card (after ten minutes of play) or your review with an edit button.
private struct ReviewCard: View {
    let game: GameItem
    let state: SteamUI.AppReviewState
    let minutes: Int
    @ObservedObject var page: GamePageModel
    @EnvironmentObject var engine: EngineModel
    @State private var composing: ReviewComposer.Draft?

    private func t(_ key: String, _ args: String...) -> String { engine.strings.text(key, args) ?? key }

    var body: some View {
        Group {
            switch state {
            case .none where minutes >= 10:
                card {
                    Text(t("AppDetails_Review_PlayedForTime", GamePage.playtime(minutes, engine.strings)))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 14) {
                        Text(t("AppDetails_Review_RecommendGame")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        vote(true)
                        vote(false)
                    }
                }
            case .reviewed(let r):
                card {
                    HStack(spacing: 10) {
                        Image(systemName: r.votedUp ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                            .font(.system(size: 16)).foregroundStyle(Theme.text)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t(r.votedUp ? "AppDetails_Review_Recommended" : "AppDetails_Review_NotRecommended"))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(t("AppDetails_Review_PlaytimeAtReview", GamePage.playtime(r.playtimeAtReview, engine.strings)))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Button(t("AppDetails_Review_ViewOrEdit")) { composing = .init(votedUp: r.votedUp, previous: r) }
                    }
                    if !r.text.isEmpty {
                        Text(EulaText.bbcode(r.text)).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(t("AppDetails_Review_UpVotes")) \(r.votesUp)    \(t("AppDetails_Review_Comments")) \(r.comments)")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            default:
                EmptyView()
            }
        }
        .sheet(item: $composing) { draft in
            ReviewComposer(game: game, minutes: minutes, draft: draft) {
                composing = nil
                Task { await page.reloadReview(game.appid, ui: engine.ui) }
            } cancel: { composing = nil }
        }
    }

    private func card<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("AppDetails_Review_YourReview")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            body()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
    }

    private func vote(_ up: Bool) -> some View {
        Button { composing = .init(votedUp: up, previous: nil) } label: {
            Label(t(up ? "AppDetails_Review_RecommendGameButton_Yes" : "AppDetails_Review_RecommendGameButton_No"),
                  systemImage: up ? "hand.thumbsup" : "hand.thumbsdown")
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 14).frame(height: 30)
                .foregroundStyle(Theme.text)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

/// Steam's review dialog, natively: vote, text, visibility, comments. Posting goes through the same
/// requests the client's dialog makes (SteamUI.submitReview).
struct ReviewComposer: View {
    struct Draft: Identifiable {
        var votedUp: Bool
        var previous: SteamUI.AppReview?
        var id: String { (previous?.id ?? "new") + (votedUp ? "+" : "-") }
    }

    let game: GameItem
    let minutes: Int
    let draft: Draft
    let done: () -> Void
    let cancel: () -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var votedUp = true
    @State private var text = ""
    @State private var isPublic = true
    @State private var allowComments = true
    @State private var error: String?
    @State private var posting = false

    private func t(_ key: String, _ args: String...) -> String { engine.strings.text(key, args) ?? key }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("WriteReview_Dialog_Title")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(game.name).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Text(t("WriteReview_Dialog_Playtime", GamePage.playtime(minutes, engine.strings))).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            HStack(spacing: 12) {
                Text(t(draft.previous == nil ? "WriteReview_Dialog_RecommendGame" : "WriteReview_Dialog_RecommendGame_Revise"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: $votedUp) {
                    Label(t("WriteReview_Dialog_Yes"), systemImage: "hand.thumbsup").tag(true)
                    Label(t("WriteReview_Dialog_No"), systemImage: "hand.thumbsdown").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.hairline))
            HStack(spacing: 20) {
                Picker(t("WriteReview_Dialog_Visibility"), selection: $isPublic) {
                    Text(t("WriteReview_Dialog_Public")).tag(true)
                    Text(t("WriteReview_Dialog_Friends")).tag(false)
                }
                .fixedSize()
                Toggle(t("WriteReview_Dialog_AllowComments"), isOn: $allowComments)
                Spacer()
            }
            .font(.system(size: 12))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.bad) }
            HStack {
                Spacer()
                Button(t("Button_Close"), action: cancel).keyboardShortcut(.cancelAction)
                Button(t(draft.previous == nil ? "WriteReview_Dialog_PostReview" : "WriteReview_Dialog_ReviseReview"), action: post)
                    .keyboardShortcut(.defaultAction)
                    .disabled(posting || !engine.uiOnline)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.background)
        .onAppear {
            votedUp = draft.votedUp
            text = draft.previous?.text ?? ""
            isPublic = draft.previous?.isPublic ?? true
        }
    }

    private func post() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = t("WriteReview_Dialog_NoTextError"); return }
        posting = true
        error = nil
        let ui = engine.ui, appid = game.appid, previous = draft.previous
        let (up, body, open, comments) = (votedUp, text, isPublic, allowComments)
        Task {
            do {
                try await ui.submitReview(appid, votedUp: up, text: body, isPublic: open, allowComments: comments, revising: previous)
                done()
            } catch {
                self.error = t("WriteReview_Dialog_GenericError")
                posting = false
            }
        }
    }
}

// MARK: - Notes

/// Shows a note rendered from its BBCode, or edits title and text; saving writes the client's notes file.
struct NoteEditor: View {
    enum Target: Identifiable {
        case new
        case note(SteamUI.AppNote)
        var id: String { if case .note(let n) = self { return n.id }; return "new" }
    }

    let appid: UInt32
    let name: String
    let target: Target
    var saved: () -> Void = {}
    let close: () -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var title = ""
    @State private var text = ""
    @State private var editing = false
    @State private var error: String?
    @State private var saving = false

    private var note: SteamUI.AppNote? { if case .note(let n) = target { return n }; return nil }
    private func t(_ key: String, _ fallback: String) -> String { engine.strings(key) ?? fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(engine.strings("UserGameNotes_NotesForGame", name) ?? String(localized: "\(name) 笔记")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if editing {
                TextField(t("UserGameNotes_UntitledNote_Title", String(localized: "未命名笔记")), text: $title)
                    .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold))
                TextEditor(text: $text)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(8)
                    .frame(minHeight: 240)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
            } else {
                Text(title.isEmpty ? t("UserGameNotes_Untitled", String(localized: "无标题")) : title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                ScrollView {
                    Text(EulaText.bbcode(text)).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 240)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.bad) }
            HStack {
                Spacer()
                Button(t("Button_Close", String(localized: "关闭")), action: close).keyboardShortcut(.cancelAction)
                if editing {
                    Button(t("Button_Save", String(localized: "保存")), action: save).keyboardShortcut(.defaultAction).disabled(saving || !engine.uiOnline)
                } else {
                    Button(t("UserGameNotes_Edit", String(localized: "编辑"))) { editing = true }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.background)
        .onAppear {
            title = note?.title ?? t("UserGameNotes_UntitledNote_Title", String(localized: "未命名笔记"))
            text = note?.content ?? ""
            editing = note == nil
        }
    }

    private func save() {
        saving = true
        let ui = engine.ui, (id, title, text) = (note?.id, title, text)
        Task {
            do {
                try await ui.saveAppNote(appid, id: id, title: title, content: text)
                saved()
                close()
            } catch {
                self.error = engine.strings("UserGameNotes_ErrorSavingNotes", error.localizedDescription) ?? String(localized: "保存笔记时出错。")
                saving = false
            }
        }
    }
}
