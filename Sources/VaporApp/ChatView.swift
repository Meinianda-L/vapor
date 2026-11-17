import SwiftUI
import VaporKit

/// One friend's conversation, like Steam's chat window: history from the client, polled while visible.
struct ChatView: View {
    @EnvironmentObject var engine: EngineModel
    let friend: SteamUI.Friend
    var onClose: () -> Void

    @State private var messages: [SteamUI.ChatMessage]?
    @State private var failed = false
    @State private var draft = ""
    @State private var sending = false
    @State private var sendFailed = false
    @State private var sendTask: Task<Void, Never>?
    /// Answers older than the newest request are dropped, so a slow poll cannot undo a fresh send.
    @State private var requestSeq = 0
    @FocusState private var focused: Bool

    private static let maxLength = 4000
    private static let groupGap = 300

    private var unread: Int { engine.chats.first { $0.steamID == friend.steamID }?.unread ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            conversation
            Divider().overlay(Theme.hairline)
            composer
        }
        .background(Theme.background)
        .task(id: friend.steamID) {
            messages = nil
            failed = false
            draft = ""
            sendFailed = false
            focused = true
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { sendTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Avatar(url: friend.avatar, name: friend.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name.isEmpty ? friend.steamID : friend.name)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(friend.statusLine(engine)).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "关闭聊天"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 14)
    }

    private struct Group: Identifiable {
        let id: Int
        let fromMe: Bool
        let time: Int
        var lines: [(id: Int, message: SteamUI.ChatMessage)]
    }

    /// Consecutive lines from one sender within five minutes share a bubble column and one timestamp.
    private func groups(_ list: [SteamUI.ChatMessage]) -> [Group] {
        var out: [Group] = []
        var lastTime = 0
        for (i, m) in list.enumerated() {
            if var g = out.last, g.fromMe == m.fromMe, m.time - lastTime <= Self.groupGap {
                g.lines.append((i, m))
                out[out.count - 1] = g
            } else {
                out.append(Group(id: i, fromMe: m.fromMe, time: m.time, lines: [(i, m)]))
            }
            lastTime = m.time
        }
        return out
    }

    @ViewBuilder
    private var conversation: some View {
        if let messages {
            if messages.isEmpty {
                Text(String(localized: "还没有聊天记录")).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(groups(messages)) { GroupView(group: $0, name: friend.name, me: engine.account?.persona ?? "") }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: messages.count) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        } else {
            Text(failed ? String(localized: "读取聊天记录失败，稍后重试") : String(localized: "正在读取…"))
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
            TextField(engine.uiOnline ? String(localized: "发消息") : String(localized: "Windows Steam 未运行，暂时无法发送"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1...6)
                .focused($focused)
                .disabled(!engine.uiOnline)
                .onSubmit(send)
                .onChange(of: draft) {
                    if draft.count > Self.maxLength { draft = String(draft.prefix(Self.maxLength)) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairline))
                EmoticonPickerButton(onEmoticon: { draft = draft.appendingEmoticon($0); focused = true },
                                     onSticker: { sendSticker($0) })
                    .padding(.bottom, 3)
            }
            if sendFailed {
                Text(String(localized: "发送失败，消息仍保留在输入框里")).font(.system(size: 11)).foregroundStyle(Theme.bad)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func refresh() async {
        requestSeq += 1
        let seq = requestSeq
        let id = friend.steamID
        do {
            let list = try await engine.ui.chat(with: id)
            guard !Task.isCancelled, seq == requestSeq, id == friend.steamID else { return }
            failed = false
            if list != messages { messages = list }
            if unread > 0 { try? await engine.ui.markChatRead(id) }
        } catch {
            guard !Task.isCancelled, seq == requestSeq, id == friend.steamID else { return }
            if messages == nil { failed = true }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, engine.uiOnline else { return }
        draft = ""
        deliver(text)
    }

    /// A sticker is a message of its own, as Steam's picker sends it; the draft stays as it is.
    private func sendSticker(_ name: String) {
        guard !sending, engine.uiOnline else { return }
        deliver("/sticker \(name)", restoreOnFailure: false)
    }

    private func deliver(_ text: String, restoreOnFailure: Bool = true) {
        let id = friend.steamID
        sending = true
        sendFailed = false
        sendTask = Task {
            defer { sending = false }
            do {
                try await engine.ui.sendChat(to: id, text)
                guard !Task.isCancelled, id == friend.steamID else { return }
                await refresh()
            } catch {
                guard !Task.isCancelled, id == friend.steamID else { return }
                sendFailed = true
                if restoreOnFailure && draft.isEmpty { draft = text }
            }
        }
    }

    private struct GroupView: View {
        let group: Group
        let name: String
        /// The signed-in user's name, for their own /me lines.
        let me: String

        private static let clock: DateFormatter = {
            let f = DateFormatter()
            f.locale = AppLanguage.locale
            f.dateFormat = "HH:mm"
            return f
        }()
        private static let dated: DateFormatter = {
            let f = DateFormatter()
            f.locale = AppLanguage.locale
            f.dateFormat = String(localized: "M月d日 HH:mm")
            return f
        }()

        /// "/me waves" reads as "<name> waves", in italics.
        private func blocks(_ m: SteamChatMarkup.Message, author: String) -> [RichBlock] {
            guard m.isAction else { return m.blocks }
            var out = m.blocks.map { b -> RichBlock in
                guard case var .paragraph(spans) = b else { return b }
                for i in spans.indices { spans[i].italic = true }
                return .paragraph(spans)
            }
            let name = RichSpan(author + " ", bold: true, italic: true)
            if case let .paragraph(spans)? = out.first { out[0] = .paragraph([name] + spans) } else { out.insert(.paragraph([name]), at: 0) }
            return out
        }

        private var stamp: String {
            let date = Date(timeIntervalSince1970: TimeInterval(group.time))
            return (Calendar.current.isDateInToday(date) ? Self.clock : Self.dated).string(from: date)
        }

        var body: some View {
            VStack(alignment: group.fromMe ? .trailing : .leading, spacing: 3) {
                Text(stamp).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    .padding(.bottom, 1)
                ForEach(group.lines, id: \.id) { line in
                    VStack(alignment: group.fromMe ? .trailing : .leading, spacing: 2) {
                        let message = SteamChatMarkup.parse(line.message.text)
                        // Emoticon-only and /me lines stand on their own, as in Steam's chat.
                        let plain = message.onlyEmoticons || message.isAction
                        RichBlocksView(blocks: blocks(message, author: group.fromMe ? me : name), size: 13, maxImage: 320,
                                       largeEmoticons: message.onlyEmoticons)
                            .tint(Theme.text)
                            .padding(.horizontal, plain ? 2 : 11).padding(.vertical, plain ? 2 : 7)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(plain ? Color.clear : group.fromMe ? Theme.accent.opacity(0.16) : Theme.surface))
                        if line.message.failed {
                            Text(String(localized: "发送失败")).font(.system(size: 11)).foregroundStyle(Theme.bad)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: group.fromMe ? .trailing : .leading)
            .padding(group.fromMe ? .leading : .trailing, 60)
        }
    }
}
