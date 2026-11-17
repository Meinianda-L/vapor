import SwiftUI
import VaporKit

/// Confirms an uninstall in the app's own sheet, in the style of `InstallSheet`.
struct UninstallSheet: View {
    let appid: UInt32?
    let names: [String]
    /// Runs the uninstall and closes the sheet; `dismiss` is Cancel.
    let confirm: () -> Void
    let dismiss: () -> Void
    @EnvironmentObject var engine: EngineModel

    init(appid: UInt32? = nil, names: [String], confirm: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.appid = appid
        self.names = names
        self.confirm = confirm
        self.dismiss = dismiss
    }

    private var size: Int64? {
        guard let appid, let n = engine.steamApps[appid]?.sizeOnDisk, n > 0 else { return nil }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("卸载 \(names.joined(separator: "、"))").font(.system(size: 15, weight: .semibold))
            Text(String(localized: "会删除本地游戏文件") + (size.map { "（\(bytes($0))）" } ?? "") + String(localized: "。开启了 Steam 云的存档不受影响，之后可以随时重新安装。"))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(String(localized: "卸载"), role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}

/// Asks for the name of a new collection that starts with the game.
struct NewCollectionSheet: View {
    let confirm: (String) -> Void
    let dismiss: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "新收藏")).font(.system(size: 15, weight: .semibold))
            TextField(String(localized: "收藏名称"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button(String(localized: "取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(String(localized: "创建"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        confirm(trimmed)
        dismiss()
    }
}
