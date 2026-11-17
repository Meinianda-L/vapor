import Foundation

/// A native Win32 window of the Windows Steam client — a steam.exe message box ("Steam 需要联网才能更新"),
/// the bootstrapper's update progress, wineboot's wait window — as vapor-winwatch.exe reads it. The window
/// itself never reaches the Mac screen (Shim/steamhide.m); Vapor shows and answers it instead.
public struct NativeWindow: Identifiable, Equatable, Sendable, Decodable {
    public struct Button: Identifiable, Equatable, Sendable, Decodable {
        public let hwnd: Int
        /// The Win32 command id: 1 OK, 2 Cancel, 3 Abort, 4 Retry, 5 Ignore, 6 Yes, 7 No for message boxes.
        public let command: Int
        /// The label without its `&` mnemonic marker.
        public let label: String
        public let isDefault: Bool
        public let enabled: Bool
        public var id: Int { hwnd }
        public var isCancel: Bool { command == 2 }

        enum CodingKeys: String, CodingKey { case hwnd, id, label, `default`, enabled }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hwnd = try c.decode(Int.self, forKey: .hwnd)
            command = (try? c.decode(Int.self, forKey: .id)) ?? 0
            label = NativeWindow.withoutMnemonic((try? c.decode(String.self, forKey: .label)) ?? "")
            isDefault = (try? c.decode(Bool.self, forKey: .default)) ?? false
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        }
    }

    public struct Progress: Equatable, Sendable, Decodable {
        public let position: Int
        public let minimum: Int
        public let maximum: Int
        public let marquee: Bool
        /// Nil for a marquee bar or an empty range.
        public var fraction: Double? {
            guard !marquee, maximum > minimum else { return nil }
            return min(max(Double(position - minimum) / Double(maximum - minimum), 0), 1)
        }

        enum CodingKeys: String, CodingKey { case pos, min, max, marquee }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            position = (try? c.decode(Int.self, forKey: .pos)) ?? 0
            minimum = (try? c.decode(Int.self, forKey: .min)) ?? 0
            maximum = (try? c.decode(Int.self, forKey: .max)) ?? 0
            marquee = (try? c.decode(Bool.self, forKey: .marquee)) ?? false
        }
    }

    public let hwnd: Int
    public let pid: Int
    /// The owning process's image name, e.g. "steam.exe".
    public let process: String
    public let windowClass: String
    public let title: String
    /// Static and edit text in the window's order, minus empty controls.
    public let texts: [String]
    public let buttons: [Button]
    public let progress: Progress?
    public var id: Int { hwnd }

    /// Steam's bootstrapper (update download/extract/install) and windows with nothing to answer are a
    /// status line in Vapor, not a question.
    public var isStatus: Bool { windowClass == "BootstrapUpdateUIClass" || buttons.isEmpty }
    /// The quiet status line for a status window, e.g. "正在更新 Steam… 42%".
    public var statusLine: String {
        let what: String
        if windowClass == "BootstrapUpdateUIClass" { what = "正在更新 Steam…" }
        else if process == "wineboot.exe" { what = "正在更新 Wine 配置…" }
        else { what = texts.first ?? (title.isEmpty ? "Steam" : title) }
        guard let f = progress?.fraction else { return what }
        return "\(what) \(Int((f * 100).rounded()))%"
    }

    /// What closing the window would press: its Cancel, else its only button.
    public var cancelButton: Button? { buttons.first(where: \.isCancel) ?? (buttons.count == 1 ? buttons.first : nil) }

    enum CodingKeys: String, CodingKey { case hwnd, pid, process, `class`, title, texts, buttons, progress }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hwnd = try c.decode(Int.self, forKey: .hwnd)
        pid = (try? c.decode(Int.self, forKey: .pid)) ?? 0
        process = ((try? c.decode(String.self, forKey: .process)) ?? "").lowercased()
        windowClass = (try? c.decode(String.self, forKey: .class)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        texts = ((try? c.decode([String].self, forKey: .texts)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        buttons = (try? c.decode([Lenient<Button>].self, forKey: .buttons))?.compactMap(\.value) ?? []
        progress = try? c.decode(Progress.self, forKey: .progress)
    }

    /// "&Retry" → "Retry", "R&&D" → "R&D".
    static func withoutMnemonic(_ s: String) -> String {
        var out = "", pending = false
        for ch in s {
            if ch == "&" && !pending { pending = true; continue }
            pending = false
            out.append(ch)
        }
        return out
    }
}

private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Runs vapor-winwatch.exe in Steam's prefix (same Wine and environment, so the same wineserver) and keeps
/// the list of native windows it reports. Starting is idempotent; the helper exits with Vapor (its stdin
/// closes) or with the prefix (wineserver -k).
public final class NativeWindows: @unchecked Sendable {
    public static let helperName = "vapor-winwatch.exe"

    /// One line of the helper's output.
    enum Event: Equatable {
        case ready
        case show(NativeWindow)
        case gone(hwnd: Int)

        init?(line: Data) {
            struct Head: Decodable { let event: String; let hwnd: Int? }
            guard let head = try? JSONDecoder().decode(Head.self, from: line) else { return nil }
            switch head.event {
            case "ready": self = .ready
            case "show": guard let w = try? JSONDecoder().decode(NativeWindow.self, from: line) else { return nil }; self = .show(w)
            case "gone": guard let h = head.hwnd else { return nil }; self = .gone(hwnd: h)
            default: return nil
            }
        }
    }

    private let wine: URL
    private let environment: [String: String]
    private let helper: URL?
    private let arguments: [String]
    private let log: URL?
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()
    private var list: [NativeWindow] = []
    private var observers: [@Sendable ([NativeWindow]) -> Void] = []
    /// A helper that died on its own is not relaunched more often than this.
    private var lastLaunch: Date?

    /// `arguments` go to the helper after its path (tests watch their own process with `--watch`).
    init(wine: URL, environment: [String: String], helper: URL?, log: URL?, arguments: [String] = []) {
        self.wine = wine
        self.environment = environment
        self.helper = helper
        self.arguments = arguments
        self.log = log
    }

    deinit {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
    }

    /// The windows shown now, oldest first.
    public var windows: [NativeWindow] { lock.withLock { list } }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// Calls `handler` with the current list now and after every change, on a background thread.
    public func observe(_ handler: @escaping @Sendable ([NativeWindow]) -> Void) {
        let now = lock.withLock { observers.append(handler); return list }
        handler(now)
    }

    /// Launches the helper unless it runs already; a no-op when this build has no helper.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard let helper, process?.isRunning != true else { return }
        if let lastLaunch, Date().timeIntervalSince(lastLaunch) < 10 { return }
        lastLaunch = Date()
        let p = Process()
        p.executableURL = wine
        p.arguments = [helper.path] + arguments
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = log.flatMap { url -> FileHandle? in
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let h = try? FileHandle(forWritingTo: url)
            _ = try? h?.seekToEnd()
            return h
        } ?? FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { self?.received(data) }
        }
        p.terminationHandler = { [weak self] ended in self?.ended(ended) }
        guard (try? p.run()) != nil else { return }
        process = p
        input = stdin.fileHandleForWriting
        pending = Data()
    }

    /// Ends the helper; the next `start` launches it at once.
    public func stop() {
        let (p, i) = lock.withLock { () -> (Process?, FileHandle?) in
            defer { process = nil; input = nil; lastLaunch = nil }
            return (process, input)
        }
        try? i?.close()
        if let p, p.isRunning { p.terminate() }
        publish { $0.removeAll() }
    }

    /// Presses a button of a shown window (posts the button's WM_COMMAND to its dialog).
    public func press(_ button: NativeWindow.Button) { send("click \(button.hwnd)") }

    /// What the window's close box would do (WM_CLOSE).
    public func close(_ window: NativeWindow) { send("close \(window.hwnd)") }

    private func send(_ command: String) {
        let handle = lock.withLock { input }
        try? handle?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func received(_ data: Data) {
        let lines: [Data] = lock.withLock {
            pending.append(data)
            var out: [Data] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                out.append(pending[pending.startIndex..<nl])
                pending = Data(pending[(nl + 1)...])
            }
            return out
        }
        let events = lines.compactMap(Event.init(line:))
        guard !events.isEmpty else { return }
        publish { list in for e in events { Self.apply(e, to: &list) } }
    }

    private func ended(_ p: Process) {
        let current = lock.withLock { () -> Bool in
            guard process === p else { return false }
            process = nil
            input = nil
            return true
        }
        if current { publish { $0.removeAll() } }
    }

    private func publish(_ change: (inout [NativeWindow]) -> Void) {
        let (changed, now, handlers) = lock.withLock { () -> (Bool, [NativeWindow], [@Sendable ([NativeWindow]) -> Void]) in
            let before = list
            change(&list)
            return (list != before, list, observers)
        }
        if changed { for h in handlers { h(now) } }
    }

    static func apply(_ event: Event, to list: inout [NativeWindow]) {
        switch event {
        case .ready: list.removeAll()
        case let .show(w):
            if let i = list.firstIndex(where: { $0.hwnd == w.hwnd }) { list[i] = w } else { list.append(w) }
        case let .gone(hwnd): list.removeAll { $0.hwnd == hwnd }
        }
    }
}
