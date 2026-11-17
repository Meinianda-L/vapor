import AppKit
import SwiftUI
import VaporKit

/// The button beside a message field that opens the picker.
struct EmoticonPickerButton: View {
    var onEmoticon: (String) -> Void
    /// Stickers are chat-only; without this the picker shows emoticons alone.
    var onSticker: ((String) -> Void)?
    @EnvironmentObject private var engine: EngineModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "face.smiling").font(.system(size: 15)).foregroundStyle(shown ? Theme.accent : Theme.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!engine.uiOnline)
        .help(String(localized: "表情和贴纸"))
        .popover(isPresented: $shown, arrowEdge: .top) {
            EmoticonPicker(onEmoticon: { onEmoticon($0) }, onSticker: onSticker.map { send in { send($0); shown = false } })
                .environmentObject(engine)
        }
    }
}

/// The user's Steam emoticons and stickers, as Steam's chat picker lists them: recent first, then all, searchable.
struct EmoticonPicker: View {
    var onEmoticon: (String) -> Void
    var onSticker: ((String) -> Void)?
    @EnvironmentObject private var engine: EngineModel
    @ObservedObject private var emoticons = Emoticons.shared
    @State private var query = ""

    private func matches(_ name: String) -> Bool {
        let q = query.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased()
        return q.isEmpty || name.lowercased().contains(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(String(localized: "搜索表情"), text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(12)
            Divider().overlay(Theme.hairline)
            ScrollView { content.padding(12) }
        }
        .frame(width: 320, height: 340)
        .background(Theme.background)
        .task { emoticons.loadList(engine.ui) }
    }

    @ViewBuilder private var content: some View {
        if let list = emoticons.list {
            let owned = Set(list.emoticons.map(\.name))
            let recent = list.recent.filter { owned.contains($0) && matches($0) }.prefix(16)
            let all = list.emoticons.map(\.name).filter(matches).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let stickers = onSticker == nil ? [] : list.stickers.filter { matches($0.name) }
            if list.emoticons.isEmpty && list.stickers.isEmpty {
                note(String(localized: "这个账户还没有 Steam 表情或贴纸。可以在点数商店兑换，或通过集换式卡牌获得。"))
            } else if all.isEmpty && stickers.isEmpty {
                note(String(localized: "没有找到匹配的表情。"))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if !recent.isEmpty && query.isEmpty { section(String(localized: "最近使用"), Array(recent)) }
                    if !all.isEmpty { section(String(localized: "表情"), all) }
                    if !stickers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: String(localized: "贴纸"))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(stickers) { s in
                                    Cell(image: emoticons.sticker(s.name), side: 64, help: s.name) { onSticker?(s.name) }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            note(engine.uiOnline ? String(localized: "正在读取…") : String(localized: "Windows Steam 在线后才能使用表情。"))
        }
    }

    private func section(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(names, id: \.self) { name in
                    Cell(image: emoticons.image(name, large: false), side: 26, help: ":\(name):") { onEmoticon(name) }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Cell: View {
        let image: NSImage?
        let side: CGFloat
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Group {
                    if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
                    else { RoundedRectangle(cornerRadius: 4).fill(Theme.surface) }
                }
                .frame(width: side, height: side)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.white.opacity(0.07) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}

extension String {
    /// `text` with ":name:" appended the way a typed emoticon would be, spaced from what came before.
    func appendingEmoticon(_ name: String) -> String {
        (isEmpty || hasSuffix(" ") || hasSuffix("\n") ? self : self + " ") + ":\(name): "
    }
}
