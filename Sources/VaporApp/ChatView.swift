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
            .help("关闭聊天")
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
                Text("还没有聊天记录").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(groups(messages)) { GroupView(group: $0, name: friend.name) }
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
            Text(failed ? "读取聊天记录失败，稍后重试" : "正在读取…")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(engine.uiOnline ? "发消息" : "Windows Steam 未运行，暂时无法发送", text: $draft, axis: .vertical)
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
            if sendFailed {
                Text("发送失败，消息仍保留在输入框里").font(.system(size: 11)).foregroundStyle(Theme.bad)
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
        let id = friend.steamID
        draft = ""
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
                if draft.isEmpty { draft = text }
            }
        }
    }

    private struct GroupView: View {
        let group: Group
        let name: String

        private static let clock: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "HH:mm"
            return f
        }()
        private static let dated: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日 HH:mm"
            return f
        }()

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
                        Text(BBCode.render(line.message.text))
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                            .tint(Theme.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(group.fromMe ? Theme.accent.opacity(0.16) : Theme.surface))
                        if line.message.failed {
                            Text("发送失败").font(.system(size: 11)).foregroundStyle(Theme.bad)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: group.fromMe ? .trailing : .leading)
            .padding(group.fromMe ? .leading : .trailing, 60)
        }
    }
}

/// The small part of Steam's chat BBCode that shows up in plain conversations.
enum BBCode {
    static func render(_ source: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(source)
        while let i = rest.firstIndex(where: { $0 == "[" || $0 == "\\" }) {
            out += AttributedString(rest[..<i])
            rest = rest[i...]
            if rest.hasPrefix("\\[") {
                out += AttributedString("[")
                rest = rest.dropFirst(2)
                continue
            }
            if rest.first == "\\" {
                out += AttributedString("\\")
                rest = rest.dropFirst()
                continue
            }
            guard let close = rest.firstIndex(of: "]") else { break }
            let tag = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
            let parts = tag.split(separator: "=", maxSplits: 1)
            let name = parts.first.map { $0.lowercased() } ?? ""
            let arg = parts.count > 1 ? String(parts[1]) : nil
            switch name {
            case "emoticon":
                out += AttributedString(":\(take(&rest, until: "[/emoticon]")):")
            case "img":
                var s = AttributedString("[图片]")
                s.link = url(take(&rest, until: "[/img]"))
                out += s
            case "url":
                let body = take(&rest, until: "[/url]")
                var s = arg == nil ? AttributedString(body) : render(body)
                s.link = url(arg ?? body)
                s.underlineStyle = .single
                out += s
            default:
                break   // closing and unknown tags (spoiler, b, i …) keep their content as plain text
            }
        }
        out += AttributedString(rest)
        return out
    }

    private static func take(_ rest: inout Substring, until close: String) -> String {
        guard let r = rest.range(of: close, options: .caseInsensitive) else {
            defer { rest = "" }
            return String(rest)
        }
        defer { rest = rest[r.upperBound...] }
        return String(rest[..<r.lowerBound])
    }

    /// Only web links are made clickable.
    private static func url(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }
}
