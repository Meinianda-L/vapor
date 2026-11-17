import SwiftUI
import VaporKit

struct SettingsView: View {
    @AppStorage("boostMode") private var boost = "off"
    @AppStorage("defaultMsync") private var msync = true
    /// The app's own language override ("" = the system's), stored where AppKit reads it at launch.
    /// Only the app's own domain: the global one always lists the system languages.
    @State private var language: String = {
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        guard let first = own?.first else { return "" }
        return first.hasPrefix("zh") ? "zh-Hans" : first.hasPrefix("en") ? "en" : ""
    }()
    @EnvironmentObject var engine: EngineModel
    @State private var steam: SteamUI.Settings?
    @State private var throttle = ""
    @FocusState private var throttleFocused: Bool
    @State private var confirmClearCache = false
    /// Values being written, by setting name, shown until settingsStore reports them back.
    @State private var pending: [String: AnyHashable] = [:]

    var body: some View {
        Form {
            if let a = engine.account {
                Section("账户") {
                    LabeledContent("昵称", value: a.persona)
                    LabeledContent("账户名称", value: a.accountName)
                    LabeledContent("Steam ID", value: a.steamID)
                    if !a.wallet.isEmpty { LabeledContent("钱包余额", value: a.wallet) }
                }
            }
            if let st = steam {
                downloads(st)
                storage(st)
                Section("Steam 云") {
                    Toggle("为支持的应用程序启用 Steam 云同步", isOn: set("cloud_enabled", st, \.cloudEnabled))
                }
                Section {
                    Toggle(engine.strings("Settings_InGame_EnableOverlay") ?? String(localized: "在游戏中启用 Steam 界面"), isOn: set("enable_overlay", st, \.overlayEnabled))
                } header: { Text("游戏中") } footer: {
                    Text("Shift+Tab 打开的好友、浏览器和市场。在 Wine 下它偶尔会让 Steam 的界面进程崩溃（Steam 会自行恢复）；遇到问题可以关掉。")
                }
            } else {
                Section("Steam") {
                    Text(engine.uiOnline ? String(localized: "正在读取 Steam 设置…") : String(localized: "Windows Steam 在线后可在这里修改它的设置。")).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("超分与插帧", selection: $boost) {
                    Text("关闭").tag("off")
                    Text("MetalFX 超分").tag("upscale")
                    Text("超分 + 插帧").tag("upscale,framegen")
                }
            } header: { Text("VaporBoost") } footer: {
                Text("在 Metal 呈现层完成，D3DMetal、DXMT、MoltenVK 都适用。插帧会多出约一帧延迟。")
            }
            Section("Wine") {
                Toggle("默认启用 MSync", isOn: $msync)
                if let steam = engine.steam {
                    LabeledContent("当前引擎", value: steam.engine.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    LabeledContent("Wine 环境", value: steam.prefix.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
            }
            Section {
                Picker("界面语言", selection: $language) {
                    Text("跟随系统").tag("")
                    // Each language is named in itself, so it can be found whatever the current one is.
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: language) { _, new in
                    if new.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([new], forKey: "AppleLanguages") }
                }
            } header: { Text("语言") } footer: {
                Text("下次打开 Vapor 时生效。Steam 自己的文字（错误信息、商店标签等）也会跟着切换。")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("设置")
                .font(.system(size: 30, weight: .bold))
                .kerning(-0.6)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 4)
        }
        .task(id: engine.uiOnline) { await reload() }
        .confirmationDialog("清除下载缓存？", isPresented: $confirmClearCache) {
            Button("清除", role: .destructive) { engine.uiAction { try await $0.clearDownloadCache() } }
        } message: { Text("可以解决下载卡住或无法开始的问题。Steam 会重新读取下载配置。") }
    }

    private func reload() async {
        guard engine.uiOnline, let st = try? await engine.ui.settings() else { return }
        show(st)
    }

    private func show(_ st: SteamUI.Settings) {
        steam = st
        // Never replace what the user is typing, or a rejected value they have not corrected yet.
        guard !throttleFocused, throttleKbps(throttle, inBits: st.rateInBits) != nil else { return }
        // While a throttle or unit write is in flight, Steam still reports the old value: refill only once
        // it reports the one being written, so the field does not flip back (or lose the entry if it fails).
        if let want = pending["download_throttle_rate"]?.base as? Int, st.throttleKbps != want { return }
        if let want = pending["download_rate_bits_per_s"]?.base as? Bool, st.rateInBits != want { return }
        // Stored in kbit/s; Steam shows KB/s unless "rate in bits" is on (its own ×8 conversion).
        let shown = st.rateInBits ? st.throttleKbps : st.throttleKbps / 8
        throttle = shown > 0 ? "\(shown)" : ""
    }

    /// The throttle field as kbit/s: empty is unlimited (0); anything but a whole number is rejected.
    private func throttleKbps(_ text: String, inBits: Bool) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0 }
        guard s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let n = Int(s) else { return nil }
        let (kbps, overflow) = n.multipliedReportingOverflow(by: inBits ? 1 : 8)
        return overflow || kbps > Int(Int32.max) ? nil : kbps
    }

    /// Converts with the unit the field was filled in (the settings last read), not a pending toggle.
    private func commitThrottle() {
        guard let st = steam, let kbps = throttleKbps(throttle, inBits: st.rateInBits) else { return }
        set("download_throttle_rate", st, \.throttleKbps).wrappedValue = kbps
    }

    /// A binding to one Steam client setting. It reads the latest settings plus the value being written,
    /// never the copy the row was built with, so a second click before Steam answers acts on what is shown.
    private func set<T: Hashable>(_ name: String, _ st: SteamUI.Settings, _ key: KeyPath<SteamUI.Settings, T>) -> Binding<T> {
        Binding(get: { (pending[name]?.base as? T) ?? (steam ?? st)[keyPath: key] }, set: { v in
            let shown = (pending[name]?.base as? T) ?? (steam ?? st)[keyPath: key]
            guard engine.uiOnline, v != shown else { return }
            pending[name] = AnyHashable(v)
            engine.uiAction { ui in
                defer { Task { @MainActor in if pending[name]?.base as? T == v { pending[name] = nil } } }
                try await ui.setSetting(name, v)
                // settingsStore applies a write a moment later: re-read until it reports the new value.
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let st = try? await ui.settings() else { continue }
                    await MainActor.run { show(st) }
                    if st[keyPath: key] == v { break }
                }
            }
        })
    }

    @ViewBuilder private func downloads(_ st: SteamUI.Settings) -> some View {
        let regionName = st.regions.first { $0.id == st.downloadRegion }?.name ?? "\(st.downloadRegion)"
        Section {
            Picker(engine.strings("DownloadSettings_SelectRegion") ?? String(localized: "下载地区"), selection: set("download_region", st, \.downloadRegion)) {
                ForEach(st.regions.sorted { ($0.name.hasPrefix("China") ? 0 : 1, $0.name) < ($1.name.hasPrefix("China") ? 0 : 1, $1.name) }, id: \.id) {
                    Text($0.name).tag($0.id)
                }
            }
            HStack {
                Text("限制下载速度")
                Spacer()
                TextField("不限制", text: $throttle)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .foregroundStyle(throttleKbps(throttle, inBits: st.rateInBits) == nil ? Theme.bad : .primary)
                    .focused($throttleFocused)
                    .onSubmit(commitThrottle)
                    .onChange(of: throttleFocused) { _, focused in if !focused { commitThrottle() } }
                Text(st.rateInBits ? "Kbps" : "KB/s").foregroundStyle(.secondary)
            }
            Toggle("游戏运行时允许下载", isOn: set("download_while_app_running", st, \.downloadWhilePlaying))
            Toggle("串流时限制下载速度", isOn: set("download_throttle_while_streaming", st, \.throttleWhileStreaming))
            Toggle("以比特/秒显示下载速率", isOn: set("download_rate_bits_per_s", st, \.rateInBits))
            Toggle("启用着色器预缓存", isOn: set("enable_shader_precache", st, \.shaderPrecache))
            Toggle("仅在指定时段自动更新游戏", isOn: set("restrict_auto_updates", st, \.restrictAutoUpdates))
            if st.restrictAutoUpdates {
                Picker("开始", selection: set("restrict_auto_updates_start", st, \.restrictStart)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("结束", selection: set("restrict_auto_updates_end", st, \.restrictEnd)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
            }
            HStack {
                Text("下载缓存")
                Spacer()
                Button("清除下载缓存…") { confirmClearCache = true }
            }
        } header: { Text("下载") } footer: {
            if !regionName.hasPrefix("China") {
                Text("当前下载地区是 \(regionName)。在国内网络下，选离你近的 China 节点通常快得多。")
            }
        }
    }

    @ViewBuilder private func storage(_ st: SteamUI.Settings) -> some View {
        Section("存储空间") {
            ForEach(st.folders, id: \.index) { f in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(f.path).font(.system(size: 12).monospaced())
                        if f.isDefault { Text("默认").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.2))).foregroundStyle(Theme.accent) }
                        Spacer()
                        Button("在访达中显示") { engine.reveal(windowsPath: f.path) }
                        if !f.isDefault { Button("设为默认") { engine.uiAction { try await $0.setDefaultLibraryFolder(f.index) } } }
                        Button("修复") { engine.uiAction { try await $0.repairLibraryFolder(f.index) } }
                    }
                    ProgressBar(fraction: f.capacity > 0 ? Double(f.capacity - f.free) / Double(f.capacity) : 0)
                    Text("已用 \(bytes(f.capacity - f.free)) · 可用 \(bytes(f.free)) · 共 \(bytes(f.capacity))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
