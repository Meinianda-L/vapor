import AppKit
import SwiftUI
import VaporKit

extension View {
    /// Presents Steam's windows and questions (`EngineModel.steamDialog`) as Vapor sheets. Steam's own window for
    /// them never opens: the agent keeps every Steam popup hidden and answers from here.
    func steamDialogs() -> some View { modifier(SteamDialogsModifier()) }
}

private struct SteamDialogsModifier: ViewModifier {
    @EnvironmentObject var engine: EngineModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { engine.steamDialog }, set: { shown in
            // Closed without a button (Esc where there is no Cancel): what closing Steam's window would do.
            if shown == nil, let d = engine.steamDialog { engine.answerDialog(d.cancelChoice?.id ?? SteamUI.Dialog.dismiss) }
        })) { dialog in
            SteamDialogSheet(dialog: dialog).environmentObject(engine)
        }
    }
}

extension EngineModel {
    /// Steam's Chinese string for the text's token when there is one; failing that for the token whose English text or
    /// template (names and numbers filled in) the text is; else Steam's own (English) text.
    func say(_ t: SteamUI.Dialog.Text?) -> String {
        guard let t else { return "" }
        if let key = t.key, let s = strings.text(key, t.args) { return s }
        return strings.localize(t.text) ?? t.text
    }
}

struct SteamDialogSheet: View {
    let dialog: SteamUI.Dialog
    @EnvironmentObject var engine: EngineModel
    @State private var option: String?
    @State private var remember = false
    @State private var rendered: [String: AttributedString] = [:]

    private var name: String { engine.steamApps[dialog.appid]?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if dialog.kind == "microtxn", !name.isEmpty {
                Text(name).font(.system(size: 12.5, weight: .medium))
            }
            ForEach(Array(messages.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            switch dialog.kind {
            case "eula": eulas
            case "cdkey": keys
            case "cloudConflict": cloudTimes
            case "launchOption": options
            case "microtxn": purchase
            default: EmptyView()
            }
            if let note = dialog.note {
                Text(engine.say(note)).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: dialog.kind == "eula" ? 620 : 440)
        .task(id: dialog.id) { await renderEulas() }
    }

    private var title: String {
        let t = engine.say(dialog.title)
        return t.isEmpty ? (name.isEmpty ? engine.strings("Dialog_DefaultWindowTitle") ?? "Steam" : name) : t
    }

    private var messages: [String] {
        if dialog.kind == "launchError" {
            // The reason is Steam's EAppUpdateError text, which the agent can only hand over in English.
            let reason = engine.strings.appUpdateError(dialog.code) ?? dialog.message.first?.args.first ?? "\(dialog.code)"
            let text = dialog.details.flatMap { engine.strings("AppLaunchError_Text_Long", reason, $0) } ?? engine.strings("AppLaunchError_Text", reason)
            return [text ?? engine.say(dialog.message.first)]
        }
        let lines = dialog.message.map(engine.say).filter { !$0.isEmpty }
        // Read off Steam's page line by line; one block reads like the window it came from.
        return dialog.kind == "generic" && !lines.isEmpty ? [lines.joined(separator: "\n")] : lines
    }

    // MARK: kinds

    @ViewBuilder private var eulas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(dialog.eulas ?? []) { e in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(e.title ?? engine.strings("EulaDialog_Header") ?? "最终用户许可协议").font(.system(size: 14, weight: .semibold))
                        if let text = rendered[e.id] {
                            Text(text).font(.system(size: 12)).textSelection(.enabled)
                        } else if e.content != nil {
                            ProgressView().controlSize(.small)
                        } else if let url = URL(string: e.url.replacingOccurrences(of: "http://", with: "https://")) {
                            Link("在浏览器中阅读", destination: url).font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 340)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
    }

    private func renderEulas() async {
        for e in dialog.eulas ?? [] where rendered[e.id] == nil {
            guard let content = e.content else { continue }
            rendered[e.id] = await Task.detached(priority: .userInitiated) { EulaText.render(content) }.value
        }
    }

    @ViewBuilder private var keys: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(dialog.keys ?? [], id: \.key) { k in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.name).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Text(k.key).font(.system(size: 14, weight: .medium).monospaced()).textSelection(.enabled)
                    }
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(k.key, forType: .string)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            }
        }
    }

    @ViewBuilder private var cloudTimes: some View {
        if dialog.localTime > 0 || dialog.remoteTime > 0 {
            VStack(alignment: .leading, spacing: 6) {
                timeRow(engine.strings("CloudConflict_KeepLocal") ?? "本地存档", dialog.localTime)
                timeRow(engine.strings("CloudConflict_KeepRemote") ?? "云存档", dialog.remoteTime)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        }
    }

    private func timeRow(_ label: String, _ time: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(time > 0 ? Date(timeIntervalSince1970: TimeInterval(time))
                .formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))) : "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }

    /// Launch options are the dialog's non-cancel buttons; picked here, started with 开始游戏.
    private var launchChoices: [SteamUI.Dialog.Choice] { dialog.buttons.filter { $0.role != "cancel" } }

    @ViewBuilder private var options: some View {
        VStack(spacing: 0) {
            ForEach(launchChoices) { c in
                Button { option = c.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: (option ?? launchChoices.first?.id) == c.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle((option ?? launchChoices.first?.id) == c.id ? Theme.accent : Theme.tertiary)
                        Text(engine.say(c.label)).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if c.id != launchChoices.last?.id { Divider().overlay(Theme.hairline) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        if let label = dialog.remember {
            Toggle(engine.say(label), isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12))
        }
    }

    /// A purchase a game asks to approve: the price, large, under the item lines above it.
    @ViewBuilder private var purchase: some View {
        if let price = dialog.details {
            Text(price)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        }
    }

    // MARK: buttons

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if !engine.uiReachable && !engine.uiOnline {
                Text("Windows Steam 已离线。").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if dialog.kind == "launchOption" {
                if let cancel = dialog.cancelChoice { choiceButton(cancel) }
                Button(engine.strings("GameAction_Play") ?? "开始游戏") {
                    engine.answerDialog(option ?? launchChoices.first?.id ?? SteamUI.Dialog.dismiss, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
            } else if dialog.buttons.isEmpty {
                Button(engine.strings("Button_Close") ?? "关闭") { engine.answerDialog(SteamUI.Dialog.dismiss) }
                    .keyboardShortcut(.cancelAction)
            } else {
                // Cancel first, the way macOS orders a sheet's buttons; Steam lists it last.
                ForEach(dialog.buttons.sorted { ($0.role == "cancel" ? 0 : 1) < ($1.role == "cancel" ? 0 : 1) }) { choiceButton($0) }
            }
        }
    }

    private func label(_ c: SteamUI.Dialog.Choice) -> String {
        dialog.kind == "microtxn" && c.id == "authorize" ? "授权" : engine.say(c.label)
    }

    @ViewBuilder private func choiceButton(_ c: SteamUI.Dialog.Choice) -> some View {
        let button = Button(label(c), role: c.role == "destructive" ? .destructive : nil) { engine.answerDialog(c.id) }
            .disabled(c.role == "disabled")
        switch c.role {
        case "cancel": button.keyboardShortcut(.cancelAction)
        case "default": button.keyboardShortcut(.defaultAction)
        default:
            // Without a Cancel, Esc takes the only way out Steam offers.
            if dialog.cancelChoice == nil && dialog.buttons.count == 1 { button.keyboardShortcut(.cancelAction) } else { button }
        }
    }
}

/// Steam launching a game itself (steam://run, a game that restarts through Steam): what Steam's "正在启动"
/// window showed, as one quiet line per launch. Empty when nothing is launching.
struct LaunchStatusView: View {
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        if !engine.launches.isEmpty {
            VStack(spacing: 8) {
                ForEach(engine.launches) { row($0) }
            }
        }
    }

    private func row(_ l: SteamUI.Launch) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.steamApps[l.appid]?.name ?? "App \(l.appid)").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(status(l)).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                if let f = l.fraction {
                    ProgressView(value: f).progressViewStyle(.linear).tint(Theme.accent).frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 12)
            if l.task == "ProcessingShaderCache" || l.request == "ProcessingShaderCache" {
                Button(engine.strings("LaunchApp_Action_SkipProcessingShaderCache") ?? "跳过") { engine.skipShaders(l) }
                    .controlSize(.small)
            }
            Button(engine.strings("GameAction_Cancel") ?? "取消") { engine.cancelLaunch(l) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Steam's own wording for the step (LaunchApp_Action_<task>), with its percentage where it has one.
    private func status(_ l: SteamUI.Launch) -> String {
        let percent = l.fraction.map { String(Int($0 * 100)) } ?? "0"
        switch l.task {
        case "RunningInstallScript" where l.details.isEmpty:
            return engine.strings("LaunchApp_Action_RunningInstallScript_NoParens") ?? "正在运行安装脚本…"
        case "RunningInstallScript":
            return engine.strings("LaunchApp_Action_RunningInstallScript", l.details) ?? "正在运行安装脚本…"
        default:
            return engine.strings("LaunchApp_Action_\(l.task)", percent) ?? engine.strings("LaunchApp_Action_Starting") ?? "正在开始启动…"
        }
    }
}
