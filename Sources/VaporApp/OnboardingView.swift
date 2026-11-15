import AppKit
import SwiftUI
import VaporKit

enum OnboardingStep: Int, CaseIterable {
    case welcome, engine, renderers, steam, firstLaunch

    var title: String {
        switch self {
        case .welcome: return "欢迎使用 Vapor"
        case .engine: return "Wine 引擎"
        case .renderers: return "图形组件"
        case .steam: return "安装 Steam"
        case .firstLaunch: return "首次启动"
        }
    }
}

enum OnboardingError: Error, LocalizedError {
    case notEngine, noEngine, noSteam, steamExited, noVariant

    var errorDescription: String? {
        switch self {
        case .notEngine: return "这个文件是渲染包，不是 Wine 引擎。"
        case .noEngine: return "还没有选定 Wine 引擎，请返回上一步。"
        case .noSteam: return "没有找到刚安装的 Windows Steam。"
        case .steamExited: return "Windows Steam 启动后意外退出了。"
        case .noVariant: return "没有任何图形组件构建成功，请重试。"
        }
    }
}

/// First-run setup: everything Windows Steam needs on a Mac that has neither Wine nor Steam for Windows.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Work: Equatable { case idle, running, failed(String) }
    enum Row: Equatable {
        case waiting
        case working(String, Double?)
        case ready(String)
        case skipped(String)
        case failed(String)
    }
    enum LaunchStage: Equatable {
        case starting, preparing
        case downloading(done: Int64, total: Int64)   // KB, as Steam's bootstrapper logs them
        case extracting, installing, connecting
    }

    @Published var step: OnboardingStep { didSet { if persist { defaults.set(step.rawValue, forKey: Self.stepKey) } } }
    @Published var work: Work = .idle

    @Published var engines: [WineEngine] = []
    @Published var enginesLoaded = false
    @Published var selectedEngineID: String?
    @Published var remote: [RemoteAsset] = []
    @Published var remoteLoaded = false
    @Published var selectedAssetID: String?
    @Published var showRemote = false
    @Published var event: DownloadEvent?
    @Published var chosen: WineEngine?

    @Published var rows: [VariantRenderer: Row] = [:]
    @Published var renderersDone = false
    @Published var d3dMetalFound = false

    @Published var prefixStep: PrefixSetup.Step?
    @Published var steamDone = false

    @Published var launch: LaunchStage = .starting
    @Published var finished = false

    private static let stepKey = "vapor.onboarding.step"
    private static let engineKey = "vapor.onboarding.engineRoot"
    private let persist: Bool
    private let defaults = UserDefaults.standard
    private var task: Task<Void, Never>?

    /// `persist: false` keeps previews and tests from touching the saved progress.
    init(persist: Bool = true) {
        self.persist = persist
        let saved = persist ? UserDefaults.standard.integer(forKey: Self.stepKey) : 0
        step = OnboardingStep(rawValue: saved) ?? .welcome
    }

    var visibleEngines: [WineEngine] { Array(engines.filter(\.usable).prefix(4)) }

    var visibleRemote: [RemoteAsset] {
        let engines = remote.filter { $0.kind == .engine }
        let preferred = engines.filter { $0.name.hasPrefix("WS12WineSikarugir") }
        let rest = engines.filter { !$0.name.hasPrefix("WS12WineSikarugir") }
        return Array((preferred + rest).prefix(4))
    }

    // MARK: - Navigation

    func advance() {
        cancel()
        if step == .engine { chosen = engines.first { $0.id == selectedEngineID && $0.usable } }
        if step == .engine, persist, let chosen { defaults.set(chosen.root.path, forKey: Self.engineKey) }
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        cancel()
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Stops whatever is running; used when going back and when the window goes away.
    func cancel() {
        task?.cancel()
        task = nil
        if work == .running { work = .idle }
        event = nil
        prefixStep = nil
        if !renderersDone { rows = [:] }
    }

    /// Loads what the current step shows; a resumed run without a remembered engine goes back to choose one.
    func enter() async {
        switch step {
        case .welcome: break
        case .engine: await loadEngines()
        case .renderers, .steam, .firstLaunch:
            if chosen == nil {
                await loadEngines()
                let saved = defaults.string(forKey: Self.engineKey)
                chosen = engines.first { $0.usable && $0.root.path == saved }
                if chosen == nil { step = .engine }
            }
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        work = .running
        task = Task { [weak self] in
            do {
                try await body()
                if !Task.isCancelled { self?.work = .idle }
            } catch {
                guard let self, !Task.isCancelled else { return }
                work = .failed(Self.describe(error))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        error is LocalizedError ? error.localizedDescription : "\(error)"
    }

    private var downloadSink: @Sendable (DownloadEvent) -> Void {
        { [weak self] event in Task { @MainActor in self?.event = event } }
    }

    // MARK: - Engine

    /// Vapor's own, Sikarugir's and Heroic's builds come first, then those with winemetal and wow64.
    nonisolated static func ranked(_ engines: [WineEngine]) -> [WineEngine] {
        func key(_ e: WineEngine) -> [Int] {
            [[.vapor, .sikarugir, .heroic].contains(e.source) ? 0 : 1, e.capabilities.hasWineMetal ? 0 : 1, e.capabilities.wow64 ? 0 : 1]
        }
        return engines.sorted { a, b in
            let ka = key(a), kb = key(b)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            return a.name.compare(b.name, options: .numeric) == .orderedDescending
        }
    }

    func loadEngines() async {
        let found = Self.ranked(await EngineCatalog.discover())
        engines = found
        enginesLoaded = true
        if !found.contains(where: { $0.id == selectedEngineID && $0.usable }) { selectedEngineID = found.first(where: \.usable)?.id }
        if !found.contains(where: \.usable) { openRemote() }
    }

    func openRemote() {
        showRemote = true
        guard !remoteLoaded, work != .running else { return }
        run { [self] in
            remote = try await EngineDownloads().remoteOptions()
            remoteLoaded = true
            selectedAssetID = visibleRemote.first?.id
        }
    }

    func downloadSelected() {
        guard let asset = visibleRemote.first(where: { $0.id == selectedAssetID }) else { return }
        run { [self] in
            event = .downloading(received: 0, total: asset.size)
            let item = try await EngineDownloads().download(asset, progress: downloadSink)
            try await adopt(item)
        }
    }

    func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 Wine 引擎压缩包（.tar.xz 或 .tar.gz）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { [self] in
            event = .extracting
            let item = try await EngineDownloads().install(archive: url, progress: downloadSink)
            try await adopt(item)
        }
    }

    private func adopt(_ item: InstalledItem) async throws {
        guard case let .engine(engine) = item else { throw OnboardingError.notEngine }
        if let reason = engine.unusableReason { throw WineSetupError.engineUnusable(reason) }
        await loadEngines()
        if !engines.contains(where: { $0.id == engine.id }) { engines.insert(engine, at: 0) }
        selectedEngineID = engine.id
        showRemote = false
        event = nil
    }

    // MARK: - Renderers

    func prepareRenderers() {
        run { [self] in try await buildRenderers() }
    }

    private func buildRenderers() async throws {
        guard let engine = chosen else { throw OnboardingError.noEngine }
        renderersDone = false
        rows = Dictionary(uniqueKeysWithValues: VariantRenderer.allCases.map { ($0, Row.waiting) })
        let known = engines.contains { $0.id == engine.id } ? engines : engines + [engine]
        var packs = RendererPacks.discover(engines: known)
        d3dMetalFound = packs.contains { $0.kind == .d3dmetal }

        var packErrors: [VariantRenderer: String] = [:]
        let missing = [VariantRenderer.dxmt, .dxvk].filter { r in !packs.contains { $0.kind == r.pack } }
        if !missing.isEmpty {
            let downloads = EngineDownloads()
            var assets: [RemoteAsset] = []
            for r in missing { rows[r] = .working("读取版本信息", nil) }
            do { assets = try await downloads.remoteOptions() } catch {
                try Task.checkCancellation()
                for r in missing { packErrors[r] = Self.describe(error) }
            }
            for r in missing where packErrors[r] == nil {
                guard let kind = r.pack, let asset = assets.first(where: { $0.kind == .pack(kind) }) else {
                    packErrors[r] = WineSetupError.noPack(r.pack ?? .dxmt).description
                    continue
                }
                do {
                    _ = try await downloads.download(asset) { event in
                        Task { @MainActor [weak self] in self?.rows[r] = Self.row(for: event) }
                    }
                } catch {
                    try Task.checkCancellation()
                    packErrors[r] = Self.describe(error)
                }
            }
        }

        packs = RendererPacks.discover(engines: known)
        for r in VariantRenderer.allCases where packErrors[r] == nil { rows[r] = .working("构建中", nil) }
        let result = await VariantBuilder().buildAll(from: engine, packs: packs)
        try Task.checkCancellation()
        for r in VariantRenderer.allCases {
            switch result[r] {
            case .built: rows[r] = .ready("已构建")
            case .upToDate: rows[r] = .ready("已就绪")
            case let .failed(message): rows[r] = .failed(message)
            case let .skipped(message):
                if let error = packErrors[r] { rows[r] = .failed(error) }
                else { rows[r] = .skipped(r == .d3dmetal ? "未检测到 Game Porting Toolkit，已跳过" : message) }
            case nil: rows[r] = .skipped("")
            }
        }
        guard rows.values.contains(where: { if case .ready = $0 { return true } else { return false } }) else {
            throw OnboardingError.noVariant
        }
        renderersDone = true
    }

    private static func row(for event: DownloadEvent) -> Row {
        let (text, fraction) = describe(event)
        return .working(text, fraction)
    }

    static func describe(_ event: DownloadEvent) -> (String, Double?) {
        switch event {
        case let .downloading(received, total):
            return ("下载中 \(megabytes(received)) / \(megabytes(total)) MB", total > 0 ? Double(received) / Double(total) : nil)
        case .verifying: return ("正在校验 SHA-256", nil)
        case .extracting: return ("正在解压", nil)
        case .validating: return ("正在检查", nil)
        case .finished: return ("完成", 1)
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return String(format: mb < 10 ? "%.1f" : "%.0f", mb)
    }

    // MARK: - Steam for Windows

    func installSteam() {
        guard let engine = chosen else { work = .failed(OnboardingError.noEngine.localizedDescription); return }
        run { [self] in
            steamDone = false
            let setup = PrefixSetup(engine: engine.root)
            _ = try await setup.run { step in Task { @MainActor [weak self] in self?.prefixStep = step } }
            var config = VaporConfig.load()
            config.engineRoot = engine.root.path
            config.steamPrefix = setup.prefix.path
            try config.save()
            steamDone = true
        }
    }

    // MARK: - First launch

    func startSteam() {
        run { [self] in
            launch = .starting
            guard let steam = WindowsSteam.detectDefault() else { throw OnboardingError.noSteam }
            try await Self.bringUp(steam) { stage in Task { @MainActor [weak self] in self?.launch = stage } }
            if persist { defaults.set(OnboardingStep.allCases.count, forKey: Self.stepKey) }
            finished = true
        }
    }

    /// Starts the client and returns once its UI answers or it reports a connection state. The first
    /// start downloads the Steam client itself, which its bootstrapper narrates in bootstrap_log.txt.
    nonisolated private static func bringUp(_ steam: WindowsSteam, update: @Sendable (LaunchStage) -> Void) async throws {
        try await Task.detached { try steam.start(silent: true) }.value
        let log = steam.steamRoot.appendingPathComponent("logs/bootstrap_log.txt")
        let began = Date()
        var goneSince: Date?
        while Date().timeIntervalSince(began) < 1800 {
            try Task.checkCancellation()
            let stage = bootstrapStage(log: tail(of: log))
            update(stage)
            if steam.isRunning {
                goneSince = nil
                switch steam.connection() {
                case .loggedOn, .loggedOff, .needsLogin: return
                case .stopped, .starting: break
                }
                if stage == .connecting, await devtoolsAnswers() { return }
            } else {
                // Steam relaunches itself after updating, so a short gap is normal.
                let since = goneSince ?? Date()
                if Date().timeIntervalSince(since) > 30 { throw OnboardingError.steamExited }
                goneSince = since
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw WineSetupError.timeout("Steam 首次启动")
    }

    nonisolated private static func devtoolsAnswers() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(SteamUI.port)/json")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    nonisolated private static func tail(of url: URL, bytes: UInt64 = 65536) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// The newest bootstrapper stage in `log`. Lines look like "Downloading update (9,228 of 336,229 KB)...".
    nonisolated static func bootstrapStage(log: String) -> LaunchStage {
        for line in log.split(whereSeparator: \.isNewline).suffix(300).reversed() {
            if line.contains("Update complete") || line.contains("Verification complete") { return .connecting }
            if line.contains("Installing update") { return .installing }
            if line.contains("Extracting package") { return .extracting }
            if let open = line.range(of: "Downloading update ("), let sizes = kilobytes(line[open.upperBound...]) {
                return .downloading(done: sizes.0, total: sizes.1)
            }
            if line.contains("Downloading") { return .preparing }
        }
        return .preparing
    }

    nonisolated private static func kilobytes(_ text: Substring) -> (Int64, Int64)? {
        let parts = text.prefix { $0 != ")" }.replacingOccurrences(of: ",", with: "").components(separatedBy: " of ")
        guard parts.count == 2, let done = Int64(parts[0]), let total = Int64(parts[1].replacingOccurrences(of: " KB", with: "")),
              total > 0 else { return nil }
        return (done, total)
    }
}

// MARK: - Views

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
            footer
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 40)
        .padding(.top, 56)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: model.step) { await model.enter() }
        .onChange(of: model.finished) { _, done in if done { onFinished() } }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= model.step.rawValue ? Theme.text : Theme.hairline).frame(height: 2)
                }
            }
            SectionLabel(text: "第 \(model.step.rawValue + 1) 步，共 \(OnboardingStep.allCases.count) 步")
            Text(model.step.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .padding(.bottom, 22)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomePage()
        case .engine: EnginePage(model: model)
        case .renderers: RenderersPage(model: model)
        case .steam: SteamPage(model: model)
        case .firstLaunch: FirstLaunchPage(model: model)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                if model.step != .welcome && model.step != .firstLaunch {
                    Button("返回", action: model.back).buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                OnboardingButton(title: primaryTitle, enabled: primaryEnabled, action: primaryAction)
            }
        }
        .padding(.top, 16)
    }

    private var running: Bool { model.work == .running }
    private var failed: Bool { if case .failed = model.work { return true } else { return false } }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "开始"
        case .engine:
            if running { return model.event == nil ? "请稍候…" : "正在安装…" }
            return model.showRemote ? "下载并使用" : "使用此引擎"
        case .renderers: return running ? "正在准备…" : model.renderersDone ? "继续" : failed ? "重试" : "下载并构建"
        case .steam: return running ? "正在安装…" : model.steamDone ? "继续" : failed ? "重试" : "安装 Steam"
        case .firstLaunch: return running ? "正在启动…" : failed ? "重试" : "启动 Steam"
        }
    }

    private var primaryEnabled: Bool {
        if running { return false }
        switch model.step {
        case .welcome, .renderers, .steam, .firstLaunch: return true
        case .engine:
            return model.showRemote ? model.visibleRemote.contains { $0.id == model.selectedAssetID }
                : model.visibleEngines.contains { $0.id == model.selectedEngineID }
        }
    }

    private func primaryAction() {
        switch model.step {
        case .welcome: model.advance()
        case .engine: model.showRemote ? model.downloadSelected() : model.advance()
        case .renderers: model.renderersDone ? model.advance() : model.prepareRenderers()
        case .steam: model.steamDone ? model.advance() : model.installSteam()
        case .firstLaunch: model.startSteam()
        }
    }
}

private struct OnboardingButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(enabled ? Color.black : Theme.secondary)
                .padding(.horizontal, 22).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(enabled ? Theme.text : Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ErrorText: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        if case let .failed(message) = model.work {
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A bar with a label above it; indeterminate when the fraction is unknown.
struct ProgressLine: View {
    let text: String
    let fraction: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.text).monospacedDigit()
                Spacer()
                if let onCancel {
                    Button("取消", action: onCancel).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            if let fraction { ProgressView(value: min(max(fraction, 0), 1)).progressViewStyle(.linear).tint(Theme.text) }
            else { ProgressView().progressViewStyle(.linear).tint(Theme.text) }
        }
    }
}

/// A selectable line: a small ring (filled in the accent when chosen), a title and one line of detail.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Circle().strokeBorder(selected ? Theme.accent : Theme.tertiary, lineWidth: 1.5)
                    .background(Circle().fill(selected ? Theme.accent : .clear).padding(3.5))
                    .frame(width: 14, height: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.white.opacity(0.07) : Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
    }
}

private struct WelcomePage: View {
    private var freeSpace: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Paragraph("Vapor 用 Windows 版 Steam 下载和运行游戏，再用原生的 Mac 界面呈现。你的 Mac 上还没有它，接下来 Vapor 会全部准备好：")
            VStack(alignment: .leading, spacing: 12) {
                item("1", "下载 Wine 引擎", "约 160 MB，已有可用引擎时可直接使用")
                item("2", "准备图形组件", "DXMT 约 19 MB，DXVK 约 3 MB")
                item("3", "创建独立的 Windows 环境并安装 Steam", "安装程序约 2 MB")
                item("4", "首次启动 Steam 并登录", "Steam 客户端本身约 300 MB")
            }
            Paragraph("全程需要联网，并占用约 2 GB 磁盘空间。Vapor 不会读取或改动 Mac 版 Steam 及其中的任何文件，两者可以同时存在。")
            if let free = freeSpace, free < 3_000_000_000 {
                Text("当前可用空间只有 \(OnboardingModel.megabytes(free)) MB，可能不够。")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
        }
    }

    private func item(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary).frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }
}

private struct EnginePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Paragraph(model.showRemote
                ? "Wine 负责在 Mac 上运行 Windows 程序。下载的文件都会校验 SHA-256，装在 Vapor 自己的目录里，不影响其他软件。推荐 Sikarugir 的 WS12 引擎，对 Steam 兼容最好。"
                : "在这台 Mac 上找到了可用的 Wine 引擎。选一个即可，推荐排在最前面的。")
            if !model.enginesLoaded && !model.showRemote {
                ProgressLine(text: "正在查找引擎…", fraction: nil)
            } else if model.showRemote {
                remoteList
            } else {
                VStack(spacing: 6) {
                    ForEach(model.visibleEngines) { e in
                        ChoiceRow(title: e.name, detail: detail(e), selected: e.id == model.selectedEngineID) {
                            model.selectedEngineID = e.id
                        }
                    }
                }
            }
            if let event = model.event {
                let (text, fraction) = OnboardingModel.describe(event)
                ProgressLine(text: text, fraction: fraction, onCancel: model.cancel)
            }
            ErrorText(model: model)
            if model.work != .running {
                HStack(spacing: 18) {
                    if model.showRemote, !model.visibleEngines.isEmpty {
                        LinkButton("使用已有的引擎") { model.showRemote = false }
                    } else if !model.showRemote {
                        LinkButton("下载新的…", action: model.openRemote)
                    }
                    LinkButton("从本地文件导入…", action: model.importArchive)
                }
            }
        }
    }

    @ViewBuilder private var remoteList: some View {
        if model.visibleRemote.isEmpty {
            if model.work == .running { ProgressLine(text: "正在读取可下载的版本…", fraction: nil) }
        } else {
            VStack(spacing: 6) {
                ForEach(model.visibleRemote) { a in
                    ChoiceRow(title: a.installName, detail: detail(a), selected: a.id == model.selectedAssetID) {
                        if model.work != .running { model.selectedAssetID = a.id }
                    }
                }
            }
        }
    }

    private func detail(_ e: WineEngine) -> String {
        var parts = [e.source.displayName]
        if let v = e.version { parts.append(v.hasPrefix("wine-") ? "Wine \(v.dropFirst(5))" : "Wine \(v)") }
        if e.capabilities.hasWineMetal { parts.append("支持 Metal 图形") }
        if e.capabilities.wow64 { parts.append("64 位") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ a: RemoteAsset) -> String {
        "\(OnboardingModel.megabytes(a.size)) MB · " + (a.sha256 == nil ? "没有校验值" : "已通过 SHA-256 校验")
    }
}

private struct RenderersPage: View {
    @ObservedObject var model: OnboardingModel

    private static let names: [(VariantRenderer, String)] = [
        (.dxmt, "DXMT"), (.dxvk, "DXVK"), (.d3dmetal, "D3DMetal"), (.wined3d, "WineD3D"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Paragraph("图形组件把游戏的 DirectX 转成 Mac 的 Metal。Vapor 会下载 DXMT（约 19 MB）和 DXVK（约 3 MB），再为每种方案生成一份独立的引擎副本，游戏可以按需切换。")
            Paragraph("D3DMetal 只来自 Apple 的 Game Porting Toolkit，Vapor 不能代为下载。装了就会自动使用，没装也不影响。")
            VStack(spacing: 0) {
                ForEach(Array(Self.names.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    line(item.0, item.1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            ErrorText(model: model)
            if model.renderersDone, model.rows.values.contains(where: { if case .failed = $0 { return true } else { return false } }) {
                LinkButton("重新尝试失败的项目", action: model.prepareRenderers)
            }
        }
    }

    private func line(_ renderer: VariantRenderer, _ name: String) -> some View {
        let row = model.rows[renderer] ?? .waiting
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text(label(row, renderer)).font(.system(size: 12)).foregroundStyle(color(row)).monospacedDigit()
                    .multilineTextAlignment(.trailing).lineLimit(2)
            }
            if case let .working(_, fraction) = row, let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.text)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func label(_ row: OnboardingModel.Row, _ renderer: VariantRenderer) -> String {
        switch row {
        case .waiting:
            if renderer == .d3dmetal { return model.d3dMetalFound ? "已检测到" : "可选" }
            return "等待"
        case let .working(text, _): return text
        case let .ready(text): return text
        case let .skipped(text): return text.isEmpty ? "已跳过" : text
        case let .failed(text): return text
        }
    }

    private func color(_ row: OnboardingModel.Row) -> Color {
        switch row {
        case .ready: return Theme.ok
        case .failed: return Theme.bad
        case .working: return Theme.text
        case .waiting, .skipped: return Theme.secondary
        }
    }
}

private struct SteamPage: View {
    @ObservedObject var model: OnboardingModel

    private var prefix: String { (VaporLocations.standard.defaultSteamPrefix.path as NSString).abbreviatingWithTildeInPath }

    /// 0 creating, 1 downloading, 2 installing, 3 finished; -1 before anything ran.
    private var progress: Int {
        if model.steamDone { return 3 }
        switch model.prefixStep {
        case nil: return -1
        case .creatingPrefix: return 0
        case .downloadingSteam: return 1
        case .installingSteam: return 2
        case .finished: return 3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Paragraph("Vapor 会在 \(prefix) 创建一个只属于它的 Windows 环境，下载 Steam 官方安装程序（约 2 MB）并静默安装。这一步通常需要一两分钟，Steam 客户端本身在下一步下载。")
            VStack(spacing: 0) {
                stage(0, "创建 Windows 环境")
                Rectangle().fill(Theme.hairline).frame(height: 1)
                stage(1, "下载 Steam 安装程序")
                Rectangle().fill(Theme.hairline).frame(height: 1)
                stage(2, "安装 Steam")
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            ErrorText(model: model)
        }
    }

    private func stage(_ index: Int, _ title: String) -> some View {
        let done = progress > index, current = progress == index && model.work == .running
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(done || current ? Theme.text : Theme.secondary)
                Spacer()
                if done { Text("完成").font(.system(size: 12)).foregroundStyle(Theme.ok) }
                else if current { Text(detail(index)).font(.system(size: 12)).foregroundStyle(Theme.text).monospacedDigit() }
            }
            if current {
                if case let .downloadingSteam(received, total) = model.prefixStep, total > 0 {
                    ProgressView(value: Double(received) / Double(total)).progressViewStyle(.linear).tint(Theme.text)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.text)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func detail(_ index: Int) -> String {
        switch model.prefixStep {
        case let .downloadingSteam(received, total) where index == 1:
            return total > 0 ? "\(OnboardingModel.megabytes(received)) / \(OnboardingModel.megabytes(total)) MB" : "\(OnboardingModel.megabytes(received)) MB"
        case .creatingPrefix where index == 0: return "首次创建较慢"
        default: return "进行中"
        }
    }
}

private struct FirstLaunchPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Paragraph("Windows Steam 第一次启动时要下载自己的客户端文件，约 300 MB，之后每次启动都不会再下。它在后台运行，不会弹出窗口。完成后会进入登录页面。")
            if model.work == .running || model.finished {
                ProgressLine(text: text, fraction: fraction)
            }
            ErrorText(model: model)
        }
    }

    private var fraction: Double? {
        if case let .downloading(done, total) = model.launch { return Double(done) / Double(total) }
        return nil
    }

    private var text: String {
        switch model.launch {
        case .starting: return "正在启动 Windows Steam…"
        case .preparing: return "正在连接 Steam 更新服务器…"
        case let .downloading(done, total):
            return "正在下载 Steam 客户端 \(OnboardingModel.megabytes(done * 1024)) / \(OnboardingModel.megabytes(total * 1024)) MB"
        case .extracting: return "正在解压…"
        case .installing: return "正在安装更新…"
        case .connecting: return "正在启动 Steam 界面…"
        }
    }
}
