import Foundation
import VaporKit

/// Everything the library app page shows besides the library entry itself. Each piece comes from the
/// store steamui's own section uses (see SteamUI+AppPage) and arrives on its own: Steam answers slowly
/// from here, so a section appears when its data does and the rest of the page never waits for it.
@MainActor
final class GamePageModel: ObservableObject {
    struct Content {
        var info: SteamUI.AppPageInfo?
        var details: SteamUI.AppDetails?
        var achievements: [SteamUI.Achievement]?
        var friends: SteamUI.AppFriends?
        var activity: [SteamUI.AppActivity]?
        var badge: SteamUI.AppBadge?
        var review: SteamUI.AppReviewState?
        var notes: [SteamUI.AppNote]?
        var store: StorePage?
        var screenshots: [URL] = []
    }

    @Published private(set) var content = Content()
    /// Set once every request has answered or timed out.
    @Published private(set) var settled = false

    /// The last content per app, shown at once when the page is opened again and then refreshed.
    private static var cache: [UInt32: Content] = [:]

    func load(_ appid: UInt32, engine: EngineModel) async {
        content = Self.cache[appid] ?? Content()
        settled = false
        if let root = engine.steam?.steamRoot, let me = engine.account?.steamID {
            content.screenshots = SteamUI.localScreenshots(steamRoot: root, steamID64: me, appid: appid)
        }
        let ui = engine.ui, online = engine.uiOnline
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetch(\.store, 20) { await StorePageCache.shared.page(appid) } }
            if online {
                group.addTask { await self.fetch(\.info, 10) { try? await ui.appPageInfo(appid) } }
                group.addTask { await self.fetch(\.details, 12) { await engine.details(appid) } }
                group.addTask { await self.fetch(\.achievements, 15) { try? await ui.achievements(appid) } }
                group.addTask { await self.fetch(\.friends, 20) { try? await ui.appFriends(appid) } }
                group.addTask { await self.fetch(\.activity, 20) { try? await ui.appActivity(appid) } }
                group.addTask { await self.fetch(\.badge, 15) { try? await ui.appBadge(appid) } }
                group.addTask { await self.fetch(\.review, 15) { try? await ui.myReview(appid) } }
                group.addTask { await self.fetch(\.notes, 10) { try? await ui.appNotes(appid) } }
            }
        }
        guard !Task.isCancelled else { return }
        settled = true
        Self.cache[appid] = content
    }

    func reloadReview(_ appid: UInt32, ui: SteamUI) async {
        await fetch(\.review, 15) { try? await ui.myReview(appid) }
        Self.cache[appid]?.review = content.review
    }

    func reloadNotes(_ appid: UInt32, ui: SteamUI) async {
        await fetch(\.notes, 10) { try? await ui.appNotes(appid) }
        Self.cache[appid]?.notes = content.notes
    }

    /// Runs `body` against a timer (Steam's calls can hang and ignore cancellation); a nil answer keeps
    /// what is already shown.
    private func fetch<T: Sendable>(_ key: WritableKeyPath<Content, T?>, _ seconds: Double,
                                    _ body: @escaping @Sendable () async -> T?) async {
        let (race, finish) = AsyncStream.makeStream(of: T?.self)
        let work = Task { finish.yield(await body()) }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            finish.yield(nil)
        }
        defer { work.cancel(); timer.cancel() }
        var result: T?
        for await r in race { result = r; break }
        guard !Task.isCancelled, let result else { return }
        content[keyPath: key] = result
    }
}
