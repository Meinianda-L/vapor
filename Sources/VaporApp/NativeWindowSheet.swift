import SwiftUI
import VaporKit

/// A message box Windows Steam put up natively (steam.exe, its bootstrapper), as a Vapor sheet. The Win32
/// window stays off the screen; its buttons are pressed through `EngineModel.press`.
struct NativeWindowSheet: View {
    let window: NativeWindow
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(window.title.isEmpty ? "Steam" : window.title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !window.texts.isEmpty {
                Text(window.texts.joined(separator: "\n"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let progress = window.progress {
                if let f = progress.fraction {
                    ProgressView(value: f).progressViewStyle(.linear).tint(Theme.accent)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                // Cancel first, the way macOS orders a sheet's buttons.
                ForEach(window.buttons.sorted { ($0.isCancel ? 0 : 1) < ($1.isCancel ? 0 : 1) }) { button($0) }
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    @ViewBuilder private func button(_ b: NativeWindow.Button) -> some View {
        let view = Button(Self.label(b, in: window)) { engine.press(b, in: window) }.disabled(!b.enabled)
        if b.isDefault { view.keyboardShortcut(.defaultAction) }
        else if b.id == window.cancelButton?.id { view.keyboardShortcut(.cancelAction) }
        else { view }
    }

    /// Wine draws message box buttons in English; the standard ones get the Mac's Chinese wording.
    static func label(_ b: NativeWindow.Button, in window: NativeWindow) -> String {
        let standard = [1: ("ok", String(localized: "确定")), 2: ("cancel", String(localized: "取消")), 3: ("abort", String(localized: "中止")), 4: ("retry", String(localized: "重试")),
                        5: ("ignore", String(localized: "忽略")), 6: ("yes", String(localized: "是")), 7: ("no", String(localized: "否")), 10: ("try again", String(localized: "重试")), 11: ("continue", String(localized: "继续"))]
        if let (english, chinese) = standard[b.command], b.label.lowercased() == english { return chinese }
        return b.label
    }
}
