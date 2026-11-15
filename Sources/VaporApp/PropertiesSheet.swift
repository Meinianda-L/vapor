import SwiftUI
import VaporKit

/// Steam's game Properties dialog, natively: the same pages and settings, read from appDetailsStore and
/// written with the same SteamClient.Apps calls. Labels are Steam's own strings.
struct PropertiesSheet: View {
    let appid: UInt32
    var dismiss: () -> Void
    @EnvironmentObject var engine: EngineModel
    @State private var details: SteamUI.AppDetails?
    @State private var page: Page = .general
    @State private var launchOptions = ""
    @State private var savedLaunchOptions = ""
    @FocusState private var launchOptionsFocused: Bool
    @State private var confirmUninstall = false
    /// Values being written, by setting, shown until Steam reports them back.
    @State private var pending: [String: AnyHashable] = [:]

    enum Page: CaseIterable { case general, updates, files, betas, dlc }

    private func t(_ key: String, _ fallback: String, _ args: String...) -> String {
        guard var s = engine.strings(key) else { return fallback }
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$s", with: a) }
        return s
    }

    private func title(_ p: Page) -> String {
        switch p {
        case .general: return t("AppProperties_GeneralPage", "通用")
        case .updates: return t("AppProperties_UpdatesPage", "更新")
        case .files: return t("AppProperties_LocalFilesPage", "已安装文件")
        case .betas: return t("AppProperties_BetasPage", "游戏版本及测试版")
        case .dlc: return t("AppProperties_DLCPage", "DLC")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(details?.name ?? engine.steamApps[appid]?.name ?? "")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .padding(.horizontal, 10).padding(.bottom, 12)
                ForEach(Page.allCases.filter { $0 != .dlc || !(details?.dlc.isEmpty ?? true) }, id: \.self) { p in
                    Button { commitLaunchOptions(); page = p } label: {
                        Text(title(p)).font(.system(size: 12.5, weight: page == p ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(page == p ? Color.white.opacity(0.08) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(page == p ? Theme.text : Theme.secondary)
                }
                Spacer()
                Button("完成") { commitLaunchOptions(); dismiss() }.keyboardShortcut(.defaultAction).padding(.horizontal, 10)
            }
            .padding(16)
            .frame(width: 190)
            .background(Theme.sidebar)
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let d = details {
                        switch page {
                        case .general: general(d)
                        case .updates: updates(d)
                        case .files: files(d)
                        case .betas: betas(d)
                        case .dlc: dlc(d)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 520)
        .background(Theme.background)
        .task { await load() }
        .onDisappear { commitLaunchOptions() }
        .confirmationDialog("卸载 \(details?.name ?? "")？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { engine.uninstall(appid); dismiss() }
        } message: { Text("会删除本地游戏文件。开启了 Steam 云的存档不受影响。") }
    }

    private func load() async {
        details = await engine.details(appid)
        launchOptions = details?.launchOptions ?? ""
        savedLaunchOptions = launchOptions
    }

    /// The field is saved on Return, on losing focus, on a page change and when the sheet closes; only
    /// what changed is written, so those paths never write twice.
    private func commitLaunchOptions() {
        guard details != nil, launchOptions != savedLaunchOptions else { return }
        let v = launchOptions
        savedLaunchOptions = v
        apply { try await $0.setLaunchOptions(appid, v) }
    }

    /// Applies a setter, then re-reads details so the page shows what Steam actually stored.
    private func apply(_ body: @escaping (SteamUI) async throws -> Void) {
        engine.uiAction { ui in
            try await body(ui)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let d = try? await ui.details(appid)
            await MainActor.run { if let d { details = d } }
        }
    }

    /// A control bound to one app setting. It shows the value being written until Steam reports it
    /// (appDetailsStore updates a moment after the call), and acts on the latest details, never on the
    /// copy the page was built with. `toggle` marks a setter that flips the value instead of setting it:
    /// it is sent only when the wanted value differs from Steam's, and not again while one is in flight.
    private func bind<T: Hashable>(_ key: String, _ d: SteamUI.AppDetails, _ read: @escaping (SteamUI.AppDetails) -> T,
                                   toggle: Bool = false, write: @escaping (SteamUI, T) async throws -> Void) -> Binding<T> {
        Binding(get: { (pending[key]?.base as? T) ?? read(details ?? d) }, set: { v in
            guard let current = details.map(read), engine.uiOnline else { return }
            if toggle { guard pending[key] == nil, v != current else { return } }
            guard v != ((pending[key]?.base as? T) ?? current) else { return }
            pending[key] = AnyHashable(v)
            engine.uiAction { ui in
                defer { Task { @MainActor in if pending[key]?.base as? T == v { pending[key] = nil } } }
                try await write(ui, v)
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let d = try? await ui.details(appid) else { continue }
                    await MainActor.run { details = d }
                    if read(d) == v { break }
                }
            }
        })
    }

    // MARK: pages

    @ViewBuilder private func general(_ d: SteamUI.AppDetails) -> some View {
        group(t("AppProperties_LaunchOptionsSection", "启动选项"), t("AppProperties_LaunchOptionsDescription", "高级用户可以选择输入对启动选项的修改。") + " Vapor 启动游戏时也会带上这些参数。") {
            TextField("", text: $launchOptions)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
                .focused($launchOptionsFocused)
                .onSubmit(commitLaunchOptions)
                .onChange(of: launchOptionsFocused) { _, focused in if !focused { commitLaunchOptions() } }
        }
        if d.languages.count > 1 {
            group(t("AppProperties_SelectLanguage", "语言"), t("AppProperties_SelectLanguage_Description", "选择您希望 %1$s 使用的语言", d.name)) {
                Picker("", selection: bind("language", d, \.selectedLanguage) { try await $0.setLanguage(appid, $1) }) {
                    ForEach(d.languages, id: \.self) { l in Text(engine.strings("Language_\(l.id)") ?? l.name).tag(l.id) }
                }
                .labelsHidden().frame(width: 240)
            }
        }
        if d.cloudAvailable {
            group(t("AppProperties_SteamCloudSection", "Steam 云"), t("AppProperties_SteamCloudDescription", "Steam 云会储存信息，以便您在不同计算机上的产品体验一致。")) {
                Toggle(t("AppProperties_EnableSteamCloud", "将 %1$s 的游戏存档保存于 Steam 云", d.name),
                       isOn: bind("cloud", d, \.cloudEnabled, toggle: true) { ui, _ in try await ui.toggleCloud(appid) })
                    .disabled(!d.cloudEnabledForAccount || pending["cloud"] != nil)
                MetaLine(parts: [t("AppProperties_SteamCloudStored", "%1$s 已存储", d.cloudUsed), t("AppProperties_SteamCloudAvailable", "%1$s 可用", d.cloudFree)], size: 11)
            }
        }
    }

    @ViewBuilder private func updates(_ d: SteamUI.AppDetails) -> some View {
        if d.thirdPartyUpdater {
            Text(t("AppProperties_IsThirdPartyUpdater", "%1$s 当前使用第三方软件来升级自己的文件。", d.name)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        group(t("AppProperties_AutoUpdateSection", "自动更新"), nil) {
            Picker("", selection: bind("autoUpdate", d, \.autoUpdate) { try await $0.setAutoUpdate(appid, $1) }) {
                Text(t("AppProperties_AutoUpdateAlways", "由 Steam 决定何时更新")).tag(0)
                Text(t("AppProperties_AutoUpdateOnLaunch", "等到我启动游戏时")).tag(1)
                Text(t("AppProperties_AutoUpdateHighPriority", "立即下载更新")).tag(2)
            }
            .labelsHidden().pickerStyle(.radioGroup)
            MetaLine(parts: [t("AppProperties_AutoUpdateBuild", "生成版本 ID：%1$s", "\(d.buildID)"),
                             d.lastUpdated > 0 ? DownloadsView.time(d.lastUpdated) : ""], size: 11)
        }
        group(t("AppProperties_BackgroundDownloadsSection", "后台下载"), t("AppProperties_BackgroundDownloadsDescription", "当运行 %1$s 时，是否允许 Steam 下载其他更新？", d.name)) {
            Picker("", selection: bind("backgroundDownloads", d, \.backgroundDownloads) { try await $0.setBackgroundDownloads(appid, $1) }) {
                Text(t("AppProperties_BackgroundDownloadGlobal_Pause", "在运行时暂停后台下载") + " " + t("AppProperties_BackgroundDownloadGlobal_Description", "（按照我的 Steam 全局设置）")).tag(0)
                Text(t("AppProperties_BackgroundDownloadAlways", "始终允许后台下载")).tag(1)
                Text(t("AppProperties_BackgroundDownloadNever", "从不允许后台下载")).tag(2)
            }
            .labelsHidden().pickerStyle(.radioGroup)
        }
    }

    @ViewBuilder private func files(_ d: SteamUI.AppDetails) -> some View {
        group(t("AppProperties_LocalFilesSize", "安装大小："), nil) {
            Text(d.installed ? "\(bytes(d.diskUsage))\(d.dlcUsage > 0 ? "（含 DLC \(bytes(d.dlcUsage))）" : "")" : "未安装")
                .font(.system(size: 13, weight: .medium))
            if !d.installFolder.isEmpty {
                HStack {
                    Text(d.installFolder).font(.system(size: 11).monospaced()).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(t("AppProperties_LocalFilesBrowse", "浏览…")) { engine.reveal(windowsPath: d.installFolder) }
                }
            }
        }
        if d.installed {
            row(t("AppProperties_LocalFilesVerify_game", "验证游戏文件的完整性"), t("AppProperties_LocalFilesVerifyLabel_game", "验证此游戏的文件是否已正确安装"), "验证") {
                engine.verify(appid)
            }
            if engine.folders.count > 1 {
                group(t("AppProperties_LocalFilesMove", "移动安装文件夹"), t("AppProperties_LocalFilesMoveLabel_game", "将此游戏的内容移至另一文件夹或硬盘")) {
                    ForEach(engine.folders.filter { $0.index != d.installFolderIndex }, id: \.index) { f in
                        HStack {
                            Text(f.path).font(.system(size: 11).monospaced()).foregroundStyle(Theme.secondary)
                            Spacer()
                            Button("移到这里") { apply { try await $0.moveInstall(appid, toFolder: f.index) } }
                        }
                    }
                }
            }
            row("卸载", "删除本地游戏文件，之后可以随时重新安装。", "卸载…", destructive: true) { confirmUninstall = true }
        }
    }

    @ViewBuilder private func betas(_ d: SteamUI.AppDetails) -> some View {
        group(t("AppProperties_Beta_Selection", "已选中的游戏版本"), t("AppProperties_Beta_SelectionDescription", "此处的版本由游戏开发者提供，可能是游戏不稳定的测试版或旧版本。请谨慎操作。")) {
            Picker("", selection: bind("beta", d, \.selectedBeta) { try await $0.setBeta(appid, $1) }) {
                ForEach(d.betas, id: \.self) { b in
                    Text(b.name == "public" ? t("AppProperties_Beta_Select_Default", "默认公开版本") : b.description.isEmpty ? b.name : "\(b.name) — \(b.description)").tag(b.name)
                }
            }
            .labelsHidden().pickerStyle(.radioGroup)
            if d.hasPrivateBetas {
                Text(t("AppProperties_Beta_Private", "私密版本") + "：需要开发者提供的访问代码。").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder private func dlc(_ d: SteamUI.AppDetails) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(d.dlc) { x in
                HStack {
                    Toggle(isOn: bind("dlc\(x.id)", d, { $0.dlc.first { $0.id == x.id }?.enabled ?? x.enabled }) { try await $0.setDLC(appid, x.id, enabled: $1) }) {
                        Text(x.name).font(.system(size: 12.5))
                    }
                    Spacer()
                    Text(x.size > 0 ? bytes(x.size) : "").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                .padding(.vertical, 6)
                Divider().overlay(Theme.hairline)
            }
        }
    }

    // MARK: building blocks

    private func group<C: View>(_ title: String, _ subtitle: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            content()
        }
    }

    private func row(_ title: String, _ subtitle: String, _ button: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button(button, role: destructive ? .destructive : nil, action: action)
        }
    }
}
