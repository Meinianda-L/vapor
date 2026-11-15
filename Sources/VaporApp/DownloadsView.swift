import SwiftUI
import VaporKit

/// Steam's downloads page, rebuilt natively: same sections, same states, same words (from Steam's own
/// localization), driven by the client's download manager through SteamUI.
struct DownloadsView: View {
    @EnvironmentObject var engine: EngineModel
    let installs: [SteamInstall]

    private var all: [SteamUI.Download] { engine.downloads }
    private var active: SteamUI.Download? {
        all.first { $0.appid == engine.overview?.appid && !$0.completed } ?? all.first { $0.active && !$0.completed }
    }
    // The same buckets as downloadsStore: Queued / Unqueued / Scheduled / Completed.
    private var upNext: [SteamUI.Download] {
        all.filter { $0.isQueued && !$0.completed && $0.appid != active?.appid }.sorted { $0.queueIndex < $1.queueIndex }
    }
    private var unqueued: [SteamUI.Download] {
        all.filter { !$0.active && !$0.completed && $0.queueIndex == -1 && $0.deferredTime == 0 && $0.appid != active?.appid }
            .sorted { name($0) < name($1) }
    }
    private var scheduled: [SteamUI.Download] {
        all.filter { $0.queueIndex == -1 && $0.deferredTime != 0 && !$0.completed }.sorted { $0.deferredTime < $1.deferredTime }
    }
    private var completed: [SteamUI.Download] { all.filter(\.completed).sorted { $0.completedTime > $1.completedTime } }

    private func t(_ key: String, _ fallback: String, _ args: String...) -> String {
        guard var s = engine.strings(key) else { return fallback }
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$s", with: a) }
        return s
    }
    private func name(_ d: SteamUI.Download) -> String { engine.steamApps[d.appid]?.name ?? "App \(d.appid)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                pausedBanner
                if !engine.uiOnline {
                    Text(engine.isOnline ? "正在连接 Windows Steam…" : "Windows Steam 未运行。")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                } else {
                    RateGraph(history: engine.history, overview: engine.overview, strings: engine.strings)
                    if all.isEmpty {
                        Text(t("Downloads_NoTransfers", "队列中无下载")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    if let active {
                        section(t("Downloads_Section_Active", "进行中"), count: nil) {
                            ActiveRow(item: active, overview: engine.overview, installs: installs, t: t)
                        }
                    }
                    rows(t("Downloads_Section_Current", "即将进行"), upNext) { item, i in
                        QueueRow(item: item, installs: installs,
                                 status: i == 0 ? t("Downloads_State_UpNext", "下一个") : t("Downloads_State_Queued", "位于队列中"),
                                 actions: [.moveToTop, .remove])
                    }
                    rows(t("Downloads_Section_NotQueued", "未安排"), unqueued) { item, _ in
                        QueueRow(item: item, installs: installs,
                                 status: item.paused ? t("Downloads_State_Paused", "已暂停") : t("Downloads_State_NotQueued", "未在队列中"),
                                 actions: [.start, .remove])
                    }
                    rows(t("Downloads_Section_Scheduled", "已安排"), scheduled) { item, _ in
                        QueueRow(item: item, installs: installs,
                                 status: t("Downloads_ScheduledFor", "安排于 %1$s", Self.time(item.deferredTime)),
                                 actions: [.start, .remove])
                    }
                    if !completed.isEmpty {
                        section(t("Downloads_Section_Completed", "已完成"), count: completed.count,
                                trailing: AnyView(Button(t("Downloads_RemoveAll", "清除全部")) {
                                    for c in completed { engine.removeFromQueue(c.appid) }
                                }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.secondary))) {
                            ForEach(completed, id: \.appid) { item in
                                QueueRow(item: item, installs: installs,
                                         status: t("Downloads_DownloadFinished", "完成于：%1$s", Self.time(item.completedTime)),
                                         actions: [.remove])
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 40)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Steam keeps queued downloads suspended while all downloads are paused; say so where it matters.
    @ViewBuilder private var pausedBanner: some View {
        if engine.uiOnline && engine.downloadsPaused && all.contains(where: { !$0.completed }) {
            HStack(spacing: 12) {
                Image(systemName: "pause.circle").font(.system(size: 15)).foregroundStyle(Theme.warn)
                Text("下载已全部暂停，队列中的游戏不会开始下载。").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Button(t("Downloads_Resume", "全部恢复")) { engine.setDownloadsPaused(false) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("下载").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            // While paused, the banner below carries the resume button.
            if engine.uiOnline && !all.isEmpty && !engine.downloadsPaused {
                Button(engine.downloadsPaused ? t("Downloads_Resume", "全部恢复") : t("Downloads_PauseAll", "全部暂停")) {
                    engine.setDownloadsPaused(!engine.downloadsPaused)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            if let disk = engine.folders.first(where: \.isDefault) {
                Text("剩余 \(bytes(disk.free))").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private func rows(_ title: String, _ items: [SteamUI.Download],
                      @ViewBuilder row: @escaping (SteamUI.Download, Int) -> QueueRow) -> some View {
        if !items.isEmpty {
            section(title, count: items.count) {
                ForEach(Array(items.enumerated()), id: \.element.appid) { i, item in
                    row(item, i)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, count: Int?, trailing: AnyView? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: count.map { "\(title)（\($0)）" } ?? title)
                Spacer()
                trailing
            }
            .padding(.bottom, 8)
            content()
        }
    }

    static func time(_ t: Int) -> String {
        guard t > 0 else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(t))) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}

/// Network (filled) and disk (line) throughput over the last few minutes, with Steam's four stats.
private struct RateGraph: View {
    let history: [SteamUI.Sample]
    let overview: SteamUI.Overview?
    let strings: SteamStrings

    private var peak: Int64 { max(overview?.peakBytesPerSecond ?? 0, history.map(\.network).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Canvas { ctx, size in
                let scale = Double(max(peak, history.map(\.disk).max() ?? 0, 1))
                let n = max(history.count - 1, 1)
                func point(_ i: Int, _ v: Int64) -> CGPoint {
                    CGPoint(x: size.width * Double(i) / Double(n), y: size.height * (1 - Double(v) / scale * 0.92))
                }
                // Baseline grid.
                for f in [0.25, 0.5, 0.75] {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: size.height * f)); p.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    ctx.stroke(p, with: .color(Theme.hairline), lineWidth: 1)
                }
                guard history.count > 1 else { return }
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (i, s) in history.enumerated() { area.addLine(to: point(i, s.network)) }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                ctx.fill(area, with: .color(Theme.accent.opacity(0.22)))
                var line = Path()
                for (i, s) in history.enumerated() { i == 0 ? line.move(to: point(i, s.network)) : line.addLine(to: point(i, s.network)) }
                ctx.stroke(line, with: .color(Theme.accent), lineWidth: 1.5)
                var disk = Path()
                for (i, s) in history.enumerated() { i == 0 ? disk.move(to: point(i, s.disk)) : disk.addLine(to: point(i, s.disk)) }
                ctx.stroke(disk, with: .color(Theme.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 28) {
                stat(strings("Downloads_Stats_CurrentRate") ?? "当前", rate(overview?.networkBytesPerSecond ?? 0), Theme.accent)
                stat(strings("Downloads_Stats_PeakRate") ?? "峰值", rate(peak), nil)
                stat(strings("Downloads_Stats_TotalBytes") ?? "总计", (overview?.stages[safe: 2]?.done ?? 0) > 0 ? bytes(overview!.stages[2].done) : "—", nil)
                stat(strings("Downloads_Stats_DiskRate") ?? "磁盘使用量", rate(overview?.diskBytesPerSecond ?? 0), Theme.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ swatch: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let swatch { RoundedRectangle(cornerRadius: 1).fill(swatch).frame(width: 8, height: 8) }
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
        }
    }

    private func rate(_ b: Int64) -> String { b > 0 ? "\(bytes(b))/s" : "—" }
}

private struct ActiveRow: View {
    @EnvironmentObject var engine: EngineModel
    let item: SteamUI.Download
    let overview: SteamUI.Overview?
    let installs: [SteamInstall]
    let t: (String, String, String...) -> String

    /// The overview only describes this row when the download manager is working on this app; right
    /// after one finishes it can still point at the previous one.
    private var ov: SteamUI.Overview? { overview?.appid == item.appid ? overview : nil }
    private var paused: Bool { item.paused || engine.downloadsPaused }
    // The item's bytes cover content, workshop and shader together; the overview's stage covers only the
    // phase running now. One source per fraction, item first, as Steam's own row does.
    private var done: Int64 { item.total > 0 ? item.downloaded : ov?.stages[safe: 2]?.done ?? 0 }
    private var total: Int64 { item.total > 0 ? item.total : ov?.stages[safe: 2]?.total ?? 0 }
    private var fraction: Double {
        if total > 0 { return min(1, Double(done) / Double(total)) }
        if let o = ov, o.percent > 0 { return min(1, o.percent / 100) }
        return 0
    }

    /// The row's button acts on this download only; resuming it also lifts a global pause (see
    /// EngineModel.resume). Pausing everything is the header's job.
    private func togglePause() {
        if paused { engine.resume(item.appid) } else { engine.pause(item.appid) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ArtworkView(appid: item.appid, kind: .header, installs: installs)
                .aspectRatio(460 / 215, contentMode: .fill)
                .frame(width: 220, height: 103)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(engine.steamApps[item.appid]?.name ?? "App \(item.appid)")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button(action: togglePause) {
                        Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 12))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.text)
                    .help(paused ? t("Downloads_Resume_Tooltip", "继续下载") : t("Downloads_Pause_Tooltip", "暂停下载"))
                }
                Text(state).font(.system(size: 12)).foregroundStyle(paused ? Theme.secondary : Theme.accent)
                ProgressBar(fraction: fraction)
                MetaLine(parts: meta, size: 11.5)
            }
        }
        .padding(.vertical, 6)
    }

    private var state: String {
        if paused { return t("Downloads_State_Paused", "已暂停") }
        guard let s = ov?.state, s != "None" else { return t("Downloads_State_Starting", "正在开始下载") }
        return engine.strings("Downloads_State_\(s)") ?? s
    }

    private var meta: [String] {
        var parts = ["\(Int(fraction * 100))%"]
        if total > 0 { parts.append(t("Downloads_DownloadedBytesInProgress", "已下载 %1$s / %2$s", bytes(done), bytes(total))) }
        if !paused, let secs = ov?.secondsRemaining, secs > 0 {
            parts.append(secs >= 60 ? t("Downloads_State_MinutesRemaining", "剩余 %1$s 分钟", "\(secs / 60)")
                                    : t("Downloads_State_SecondsRemaining", "剩余 %1$s 秒", "\(secs)"))
        }
        let kinds = item.contentTypes.compactMap { k -> String? in
            switch k {
            case 0: return t("Downloads_ContentType_Content", "游戏内容")
            case 1: return t("Downloads_ContentType_Workshop", "创意工坊内容")
            case 2: return t("Downloads_ContentType_Shader", "着色器预缓存更新")
            default: return nil
            }
        }
        return parts + kinds
    }
}

private struct QueueRow: View {
    enum Action { case moveToTop, start, remove }
    @EnvironmentObject var engine: EngineModel
    let item: SteamUI.Download
    let installs: [SteamInstall]
    let status: String
    let actions: [Action]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(appid: item.appid, kind: .header, installs: installs)
                .aspectRatio(460 / 215, contentMode: .fill)
                .frame(width: 110, height: 51)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.steamApps[item.appid]?.name ?? "App \(item.appid)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                MetaLine(parts: [status, item.total > 0 && !item.completed ? "\(bytes(item.downloaded)) / \(bytes(item.total))" : ""], size: 11)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, a in button(a) }
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func button(_ a: Action) -> some View {
        let (symbol, help): (String, String) = {
            switch a {
            case .moveToTop: return ("arrow.up.to.line", engine.strings("Downloads_MoveToTop_Tooltip") ?? "立即下载")
            case .start: return ("arrow.down.circle", engine.strings("Downloads_MoveToTop_Tooltip") ?? "立即下载")
            case .remove: return ("xmark", item.completed ? "从列表中清除" : "从队列中移除")
            }
        }()
        return Button {
            // Steam's queued, unqueued and scheduled rows all use ResumeAppUpdate: it moves the app to the
            // front of the queue and clears its own pause.
            switch a {
            case .moveToTop, .start: engine.resume(item.appid)
            case .remove: engine.removeFromQueue(item.appid)
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.secondary).help(help)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
