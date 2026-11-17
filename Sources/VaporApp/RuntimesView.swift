import AppKit
import SwiftUI
import VaporKit

private func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

/// The graphics components and variants of one engine, read off the main thread.
struct RuntimesScan: Sendable {
    var engines: [WineEngine] = []
    var packs: [RendererPack] = []
    /// Engines whose variants were built from each pack, by pack id.
    var packUsers: [String: [String]] = [:]
    var configured: URL?
    var prefix: URL?
    var current: WineEngine?
    var variants: [VariantRenderer: RuntimesModel.VariantState] = [:]
    var variantPacks: [VariantRenderer: RendererPack] = [:]

    static func read(locations: VaporLocations) async -> RuntimesScan {
        var scan = RuntimesScan()
        let paths = EngineCatalog.SearchPaths.standard
        let engines = OnboardingModel.ranked(await EngineCatalog.discover(in: paths))
        let packs = RendererPacks.discover(in: paths, engines: engines)
        let steam = WindowsSteam.detectDefault()
        let config = VaporConfig.load(from: locations.config)
        scan.engines = engines
        scan.packs = packs
        scan.configured = steam?.engine ?? config.engineURL
        scan.prefix = steam?.prefix ?? config.steamPrefixURL
        let builder = VariantBuilder(outputRoot: locations.variants)

        for pack in packs {
            let want = canonical(pack.root)
            scan.packUsers[pack.id] = engines.filter { e in
                VariantRenderer.allCases.contains { r in
                    r.pack == pack.kind && builder.existingMarker(at: builder.directory(for: e, renderer: r))?.packRoot == want
                }
            }.map(\.name)
        }

        guard let configured = scan.configured else { return scan }
        scan.current = engines.first { canonical($0.root) == canonical(configured) }
        guard let engine = scan.current, engine.usable else { return scan }
        for renderer in VariantRenderer.allCases {
            var pack: RendererPack?
            if let kind = renderer.pack {
                pack = RendererPacks.preferred(kind, for: engine, among: packs)
                guard pack != nil else { scan.variants[renderer] = .noPack; continue }
                scan.variantPacks[renderer] = pack
            }
            if builder.isUpToDate(renderer, engine: engine, pack: pack) {
                scan.variants[renderer] = .current
            } else {
                let built = FileManager.default.isExecutableFile(atPath: builder.directory(for: engine, renderer: renderer).appendingPathComponent("bin/wine").path)
                // Games still run on the hand-made variants this project started with until Vapor builds its own.
                let legacy = EngineVariants.directory(for: renderer.launchRenderer, base: engine.root)?
                    .standardizedFileURL.path.hasPrefix(EngineVariants.legacyRoot.standardizedFileURL.path) == true
                scan.variants[renderer] = built ? .outdated : legacy ? .legacy : .missing
            }
        }
        return scan
    }
}

@MainActor
final class RuntimesModel: ObservableObject {
    enum Job: Equatable {
        case engine(String)
        case importing
        case pack(PackKind)
        case variant(VariantRenderer)
    }
    enum Part: Hashable { case engines, packs, variants, remote }
    enum VariantState: Equatable { case current, outdated, missing, noPack, legacy }
    enum RemoteState: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var scan = RuntimesScan()
    @Published private(set) var loaded = false
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var remote: [RemoteAsset] = []
    @Published private(set) var remoteState = RemoteState.idle
    @Published private(set) var installedRemote: Set<String> = []
    @Published private(set) var job: Job?
    @Published private(set) var batch = false
    @Published private(set) var event: DownloadEvent?
    @Published private(set) var errors: [Part: String] = [:]
    /// The engine this Vapor session's Windows Steam was started with.
    @Published var inUse: URL?

    let locations: VaporLocations
    private var task: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?

    init(locations: VaporLocations = .standard) { self.locations = locations }

    var configuredRoot: URL? { scan.configured }
    var restartPending: Bool {
        guard let inUse, let configured = scan.configured else { return false }
        return canonical(inUse) != canonical(configured)
    }

    // MARK: - Loading

    func load() async {
        let result = await Task.detached(priority: .userInitiated) { [locations] in await RuntimesScan.read(locations: locations) }.value
        guard !Task.isCancelled else { return }
        scan = result
        loaded = true
        measureSizes()
    }

    /// Disk use of each engine, one at a time off the main thread; rows fill in as they finish.
    private func measureSizes() {
        sizeTask?.cancel()
        let engines = scan.engines.filter { sizes[$0.id] == nil }
        sizeTask = Task { [weak self] in
            for engine in engines {
                let size = await Task.detached(priority: .utility) { Self.diskUse(engine.root) }.value
                guard !Task.isCancelled, let self else { return }
                sizes[engine.id] = size
            }
        }
    }

    nonisolated private static func diskUse(_ root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            if Task.isCancelled { return total }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func loadRemote() {
        guard remoteState != .loading else { return }
        remoteState = .loading
        remoteTask?.cancel()
        let locations = locations
        remoteTask = Task { [weak self] in
            do {
                let (assets, installed) = try await Self.withTimeout(25) { () -> ([RemoteAsset], Set<String>) in
                    let downloads = EngineDownloads(locations: locations)
                    let assets = try await downloads.remoteOptions()
                    return (assets, Set(assets.filter { downloads.installed($0) != nil }.map(\.id)))
                }
                guard !Task.isCancelled, let self else { return }
                remote = assets
                installedRemote = installed
                remoteState = .loaded
            } catch {
                guard !Task.isCancelled, let self else { return }
                remoteState = .failed(Self.describe(error))
            }
        }
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WineSetupError.timeout(String(localized: "读取版本信息"))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? WineSetupError { return e.description }
        return error is LocalizedError ? error.localizedDescription : String(localized: "操作没有完成。")
    }

    /// Stops what the page started when it goes away; a variant already being cloned finishes on its own.
    func stop() {
        task?.cancel()
        sizeTask?.cancel()
        remoteTask?.cancel()
    }

    func cancelJob() { task?.cancel() }

    // MARK: - Engines

    func isCurrent(_ e: WineEngine) -> Bool { scan.configured.map { canonical($0) == canonical(e.root) } ?? false }
    func isInUse(_ e: WineEngine) -> Bool { inUse.map { canonical($0) == canonical(e.root) } ?? false }

    /// The folder under Vapor's Engines that holds `e`; nil for engines Vapor did not download.
    func ownedFolder(of e: WineEngine) -> URL? {
        let base = canonical(locations.engines) + "/"
        let path = canonical(e.root)
        guard path.hasPrefix(base), let first = path.dropFirst(base.count).split(separator: "/").first else { return nil }
        return locations.engines.appendingPathComponent(String(first), isDirectory: true)
    }

    func canDelete(_ e: WineEngine) -> Bool { ownedFolder(of: e) != nil && !isCurrent(e) && !isInUse(e) && job == nil }

    func makeDefault(_ e: WineEngine) {
        guard e.usable else { return }
        errors[.engines] = nil
        var config = VaporConfig.load(from: locations.config)
        config.engineRoot = e.root.path
        do { try config.save(to: locations.config) } catch {
            errors[.engines] = String(localized: "没能保存设置：\(error.localizedDescription)")
            return
        }
        Task { await load() }
    }

    func delete(_ e: WineEngine) {
        guard canDelete(e), let folder = ownedFolder(of: e) else { return }
        errors[.engines] = nil
        let variants = locations.variants.appendingPathComponent(e.id, isDirectory: true)
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.removeItem(at: folder)
                    if FileManager.default.fileExists(atPath: variants.path) { try FileManager.default.removeItem(at: variants) }
                    return nil
                } catch { return String(localized: "没能删除：\(error.localizedDescription)") }
            }.value
            guard let self else { return }
            errors[.engines] = failure
            sizes[e.id] = nil
            await load()
        }
    }

    // MARK: - Jobs

    private var sink: @Sendable (DownloadEvent) -> Void {
        { [weak self] event in Task { @MainActor in self?.event = event } }
    }

    private func run(_ job: Job, _ part: Part, batch: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard self.job == nil else { return }
        self.job = job
        self.batch = batch
        event = nil
        errors[part] = nil
        task = Task { [weak self] in
            do { try await body() } catch {
                if !Task.isCancelled { self?.errors[part] = Self.describe(error) }
            }
            guard let self else { return }
            self.job = nil
            self.batch = false
            self.event = nil
            await load()
            if part == .remote || part == .packs { loadRemote() }
        }
    }

    func download(_ asset: RemoteAsset) {
        let part: Part = { if case .pack = asset.kind { return .packs } else { return .remote } }()
        let job: Job = { if case let .pack(kind) = asset.kind { return .pack(kind) } else { return .engine(asset.id) } }()
        let downloads = EngineDownloads(locations: locations)
        run(job, part) { [self] in
            event = .downloading(received: 0, total: asset.size)
            let item = try await downloads.download(asset, progress: sink)
            if case let .engine(e) = item, let reason = e.unusableReason { throw WineSetupError.engineUnusable(reason) }
        }
    }

    func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "选择 Wine 引擎压缩包（.tar.xz 或 .tar.gz）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let downloads = EngineDownloads(locations: locations)
        run(.importing, .remote) { [self] in
            event = .extracting
            _ = try await downloads.install(archive: url, progress: sink)
        }
    }

    // MARK: - Variants

    func rebuild(_ renderer: VariantRenderer) { rebuild([renderer], force: true, batch: false) }

    func rebuildStale() {
        rebuild(VariantRenderer.allCases.filter { [.outdated, .missing].contains(scan.variants[$0]) }, force: false, batch: true)
    }

    private func rebuild(_ renderers: [VariantRenderer], force: Bool, batch: Bool) {
        guard let engine = scan.current, engine.usable, let first = renderers.first else { return }
        let packs = scan.packs
        let builder = VariantBuilder(outputRoot: locations.variants)
        run(.variant(first), .variants, batch: batch) { [self] in
            for renderer in renderers {
                try Task.checkCancellation()
                job = .variant(renderer)
                let pack = renderer.pack.flatMap { RendererPacks.preferred($0, for: engine, among: packs) }
                _ = try await builder.build(renderer, from: engine, pack: pack, force: force)
            }
        }
    }

    // MARK: - Graphics components

    /// The release to offer for `kind`: the newest that is not a prerelease.
    func latest(_ kind: PackKind) -> RemoteAsset? {
        let all = remote.filter { $0.kind == .pack(kind) }
        return all.first { !$0.prerelease } ?? all.first
    }

    var remoteEngines: [RemoteAsset] { remote.filter { $0.kind == .engine } }
}

struct RuntimesView: View {
    @EnvironmentObject var engine: EngineModel
    @StateObject private var model: RuntimesModel
    @State private var deleting: WineEngine?
    @State private var showAllRemote = false

    init() { _model = StateObject(wrappedValue: RuntimesModel()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text(String(localized: "运行时")).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                if !model.loaded {
                    Text(String(localized: "正在查找引擎…")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                } else {
                    currentSection
                    installedSection
                    packsSection
                    variantsSection
                    remoteSection
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            model.inUse = engine.steam?.engine
            if !model.loaded { await model.load() }
            if model.remoteState == .idle { model.loadRemote() }
        }
        .onChange(of: engine.steam?.engine) { _, new in model.inUse = new }
        .onDisappear { model.stop() }
        .confirmationDialog(String(localized: "删除 \(deleting?.name ?? ")")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { e in
            Button(String(localized: "删除"), role: .destructive) { model.delete(e) }
        } message: { _ in
            Text(String(localized: "会删除这个引擎的文件和它生成的渲染器变体，不能撤销。已下载的图形组件不受影响。"))
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, error: RuntimesModel.Part? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                trailing
            }
            .padding(.bottom, 8)
            content()
            if let error, let message = model.errors[error] {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        }
    }

    private func link(_ title: String, destructive: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(!enabled ? Theme.tertiary : destructive ? Theme.bad : Theme.accent)
            .disabled(!enabled)
    }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func tidy(_ url: URL) -> String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func wineVersion(_ v: String?) -> String? {
        guard let v else { return nil }
        return v.hasPrefix("wine-") ? "Wine \(v.dropFirst(5))" : v.lowercased().hasPrefix("wine") ? v : "Wine \(v)"
    }

    private func capabilities(_ e: WineEngine) -> [String] {
        var out: [String] = []
        if e.capabilities.hasWineMetal { out.append(String(localized: "支持 DXMT")) }
        if e.capabilities.hasD3DMetal { out.append(String(localized: "含 D3DMetal")) }
        if e.capabilities.wow64 { out.append("WoW64") } else if e.capabilities.supports32Bit { out.append(String(localized: "32 位")) }
        out += e.capabilities.bundledPacks.map { String(localized: "自带 \($0.displayName)") }
        return out
    }

    private func progress(for job: RuntimesModel.Job, label: String? = nil, cancel: Bool = true) -> some View {
        var text = label ?? String(localized: "正在准备")
        var fraction: Double?
        if let event = model.event { (text, fraction) = OnboardingModel.describe(event) }
        let onCancel: (() -> Void)? = cancel ? { model.cancelJob() } : nil
        return ProgressLine(text: text, fraction: fraction, onCancel: onCancel).padding(.vertical, 8)
    }

    private func row<Lead: View, Trail: View>(@ViewBuilder lead: () -> Lead, @ViewBuilder trailing: () -> Trail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            lead()
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 11)
    }

    // MARK: - 当前引擎

    @ViewBuilder private var currentSection: some View {
        section(String(localized: "当前引擎")) {
            if let e = model.scan.current {
                VStack(alignment: .leading, spacing: 10) {
                    Text(e.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    MetaLine(parts: [e.source.displayName, wineVersion(e.version) ?? ""] + capabilities(e))
                    VStack(alignment: .leading, spacing: 6) {
                        place(String(localized: "引擎位置"), e.root)
                        if let prefix = model.scan.prefix { place(String(localized: "Steam 环境"), prefix) }
                    }
                    .padding(.top, 4)
                    if let reason = e.unusableReason {
                        Text(reason).font(.system(size: 12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.restartPending {
                        HStack(spacing: 12) {
                            Text(engine.engineSwitchBlocker ?? String(localized: "Windows Steam 目前还在用上一个引擎，切换时会重新启动它。"))
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            if engine.engineSwitchBlocker == nil {
                                link(String(localized: "立即切换"), enabled: model.job == nil) { engine.switchToConfiguredEngine() }
                            }
                        }
                    }
                }
            } else if let root = model.configuredRoot {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "设置的引擎不在已发现的列表里。")).font(.system(size: 13)).foregroundStyle(Theme.text)
                    place(String(localized: "引擎位置"), root)
                }
            } else {
                Text(String(localized: "还没有选定引擎。在下面设为默认，或下载一个新的。")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func place(_ label: String, _ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .leading)
            Text(tidy(url)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            link(String(localized: "在访达中显示")) { reveal(url) }
        }
    }

    // MARK: - 已安装的引擎

    @ViewBuilder private var installedSection: some View {
        section(String(localized: "已安装的引擎"), error: .engines) {
            if model.scan.engines.isEmpty {
                Text(String(localized: "没有找到 Wine 引擎。")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            ForEach(model.scan.engines) { e in
                row {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(e.usable ? Theme.text : Theme.secondary)
                        MetaLine(parts: [e.source.displayName, wineVersion(e.version) ?? "",
                                         model.sizes[e.id].map { bytes($0) } ?? "", status(e)], size: 11.5)
                        if let reason = e.unusableReason {
                            Text(reason).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } trailing: {
                    HStack(spacing: 14) {
                        if e.usable && !model.isCurrent(e) { link(String(localized: "设为默认")) { model.makeDefault(e) } }
                        link(String(localized: "在访达中显示")) { reveal(e.root) }
                        if model.ownedFolder(of: e) != nil { link(String(localized: "删除"), destructive: true, enabled: model.canDelete(e)) { deleting = e } }
                    }
                }
                Divider().overlay(Theme.hairline)
            }
            if model.scan.engines.contains(where: { model.ownedFolder(of: $0) != nil }) {
                Text(String(localized: "只有 Vapor 自己下载的引擎可以在这里删除。")).font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.top, 8)
            }
        }
    }

    private func status(_ e: WineEngine) -> String {
        if model.isCurrent(e) { return model.isInUse(e) || model.inUse == nil ? String(localized: "默认") : String(localized: "默认，尚未切换") }
        return e.usable ? "" : String(localized: "不可用")
    }

    // MARK: - 图形组件

    @ViewBuilder private var packsSection: some View {
        let checking = model.remoteState == .loading
        section(String(localized: "图形组件"), trailing: AnyView(HStack(spacing: 10) {
            if checking { ProgressView().controlSize(.small) }
            link(checking ? String(localized: "正在检查…") : String(localized: "检查更新"), enabled: !checking && model.job == nil) { model.loadRemote() }
        }), error: .packs) {
            ForEach(PackKind.allCases, id: \.self) { kind in
                packBlock(kind)
                Divider().overlay(Theme.hairline)
            }
            if case let .failed(message) = model.remoteState {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.bad).padding(.top, 10)
            }
        }
    }

    @ViewBuilder private func packBlock(_ kind: PackKind) -> some View {
        let packs = model.scan.packs.filter { $0.kind == kind }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        let latest = model.latest(kind)
        let haveLatest = latest.map { l in packs.contains { $0.origin == .vapor && $0.version == l.installName } } ?? false
        VStack(alignment: .leading, spacing: 0) {
            row {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                    if packs.isEmpty {
                        Text(kind == .d3dmetal ? String(localized: "没有找到。需要 Game Porting Toolkit，或自带 D3DMetal 的引擎，Vapor 不提供下载。") : String(localized: "还没有安装。"))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                if model.job == .pack(kind) {
                    EmptyView()
                } else if let latest {
                    HStack(spacing: 12) {
                        Text(haveLatest ? String(localized: "已是最新 \(latest.release)") : String(localized: "最新 \(latest.release)"))
                            .font(.system(size: 11.5)).foregroundStyle(haveLatest ? Theme.secondary : Theme.text)
                        if !haveLatest { link(packs.contains { $0.origin == .vapor } ? String(localized: "更新") : String(localized: "下载"), enabled: model.job == nil) { model.download(latest) } }
                    }
                }
            }
            if model.job == .pack(kind) { progress(for: .pack(kind)) }
            ForEach(packs) { pack in
                let users = model.scan.packUsers[pack.id] ?? []
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(pack.version).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text)
                    Text([pack.origin.displayName, users.isEmpty ? String(localized: "未被引擎变体使用") : String(localized: "用于 ") + users.joined(separator: "、")]
                        .joined(separator: "  ·  "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 7)
            }
        }
    }

    // MARK: - 渲染器变体

    private static let rendererNames: [(VariantRenderer, String, String)] = [
        (.dxmt, "DXMT", String(localized: "DirectX 11 直接转 Metal")), (.dxvk, "DXVK", String(localized: "经 Vulkan 的 DirectX 转译")),
        (.d3dmetal, "D3DMetal", String(localized: "Apple 的 DirectX 11/12 转译")), (.wined3d, "WineD3D", String(localized: "Wine 自带，不需要额外组件")),
    ]

    @ViewBuilder private var variantsSection: some View {
        let stale = VariantRenderer.allCases.contains { [.outdated, .missing].contains(model.scan.variants[$0]) }
        section(String(localized: "渲染器变体"), trailing: stale && model.job == nil ? AnyView(link(String(localized: "全部生成")) { model.rebuildStale() }) : nil, error: .variants) {
            if let e = model.scan.current, e.usable {
                ForEach(Self.rendererNames, id: \.0) { renderer, name, detail in
                    let state = model.scan.variants[renderer]
                    VStack(alignment: .leading, spacing: 0) {
                        row {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                                MetaLine(parts: [detail, model.scan.variantPacks[renderer].map { String(localized: "组件 \($0.version)") } ?? ""], size: 11.5)
                            }
                        } trailing: {
                            if model.job != .variant(renderer) {
                                HStack(spacing: 14) {
                                    Text(label(state)).font(.system(size: 12)).foregroundStyle(color(state))
                                    if state != .noPack { link(String(localized: "重新生成"), enabled: model.job == nil) { model.rebuild(renderer) } }
                                }
                            }
                        }
                        if model.job == .variant(renderer) {
                            progress(for: .variant(renderer), label: String(localized: "正在生成"), cancel: model.batch)
                        }
                    }
                    Divider().overlay(Theme.hairline)
                }
                Text(String(localized: "变体是 \(e.name) 的 APFS 克隆，只多出各自的图形库，几乎不占磁盘。游戏按渲染器选用对应的变体。"))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.top, 8)
            } else {
                Text(String(localized: "先选定一个可用的引擎。")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func label(_ s: RuntimesModel.VariantState?) -> String {
        switch s {
        case .current: return String(localized: "最新")
        case .outdated: return String(localized: "已过期")
        case .missing: return String(localized: "尚未生成")
        case .noPack: return String(localized: "缺少组件")
        case .legacy: return String(localized: "使用早期手工变体")
        case nil: return "—"
        }
    }

    private func color(_ s: RuntimesModel.VariantState?) -> Color {
        switch s {
        case .current: return Theme.ok
        case .outdated: return Theme.warn
        default: return Theme.secondary
        }
    }

    // MARK: - 下载新引擎

    @ViewBuilder private var remoteSection: some View {
        let all = model.remoteEngines
        let shown = showAllRemote ? all : Array(all.prefix(6))
        section(String(localized: "下载新引擎"), trailing: AnyView(HStack(spacing: 14) {
            link(String(localized: "从文件导入…"), enabled: model.job == nil) { model.importArchive() }
        }), error: .remote) {
            if model.job == .importing { progress(for: .importing) }
            switch model.remoteState {
            case .idle, .loading where all.isEmpty:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "正在读取可下载的版本…")).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
            case let .failed(message) where all.isEmpty:
                HStack(spacing: 14) {
                    Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.bad)
                    link(String(localized: "重试")) { model.loadRemote() }
                }
            default:
                ForEach(shown) { asset in
                    VStack(alignment: .leading, spacing: 0) {
                        row {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.installName).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                                MetaLine(parts: [asset.release + (asset.prerelease ? String(localized: "（预览版）") : ""),
                                                 "\(OnboardingModel.megabytes(asset.size)) MB",
                                                 asset.sha256 == nil ? String(localized: "没有校验值") : String(localized: "SHA-256 校验")], size: 11.5)
                            }
                        } trailing: {
                            if model.job == .engine(asset.id) {
                                EmptyView()
                            } else if model.installedRemote.contains(asset.id) {
                                Text(String(localized: "已安装")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            } else {
                                link(String(localized: "下载"), enabled: model.job == nil) { model.download(asset) }
                            }
                        }
                        if model.job == .engine(asset.id) { progress(for: .engine(asset.id)) }
                    }
                    Divider().overlay(Theme.hairline)
                }
                if all.count > shown.count {
                    link(String(localized: "显示全部 \(all.count) 个")) { showAllRemote = true }.padding(.top, 10)
                }
                if all.isEmpty {
                    Text(String(localized: "没有可下载的引擎。")).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

private extension VariantRenderer {
    /// The launch renderer this variant serves.
    var launchRenderer: Renderer {
        switch self {
        case .dxmt: return .dxmt
        case .dxvk: return .dxvkMoltenVK
        case .d3dmetal: return .d3dMetal
        case .wined3d: return .wined3d
        }
    }
}
