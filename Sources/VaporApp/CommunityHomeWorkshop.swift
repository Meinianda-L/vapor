import SwiftUI
import VaporKit

@MainActor
final class CommunityWorkshopModel: ObservableObject {
    @Published private(set) var apps: [CommunityHomeParser.WorkshopApp] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var recent = false
    private var task: Task<Void, Never>?
    private static let size = 24

    func reload(recent: Bool) {
        task?.cancel()
        self.recent = recent
        apps = []; total = 0; failed = false; loading = false
        more()
    }

    var canLoadMore: Bool { apps.count < total }

    func more() {
        guard !loading else { return }
        loading = true
        failed = false
        let recent = recent, start = apps.count
        task = Task {
            let front: CommunityHomeParser.WorkshopFront? = await Task.detached {
                guard let data = try? await CommunityClient.fetch(CommunityHomeClient.workshops(recent: recent, start: start, count: Self.size), ttl: 600) else { return nil }
                return CommunityHomeParser.workshopFront(json: data)
            }.value
            guard !Task.isCancelled, recent == self.recent, start == apps.count else { return }
            loading = false
            guard let front else { failed = true; return }
            let known = Set(apps.map(\.appid))
            apps += front.apps.filter { !known.contains($0.appid) }
            total = front.apps.isEmpty ? apps.count : front.total
        }
    }

    func cancel() { task?.cancel(); loading = false }
}

/// 创意工坊: the games with workshops; a game opens its native workshop.
struct CommunityWorkshopTab: View {
    var open: (URL) -> Void
    @StateObject private var model = CommunityWorkshopModel()
    @State private var recent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                CommunityChips(items: [(false, "按名称"), (true, "最新")], selection: $recent)
                Spacer()
                if model.total > 0 { Text("\(model.total) 个游戏").font(.system(size: 12)).foregroundStyle(Theme.tertiary).monospacedDigit() }
            }
            if model.apps.isEmpty {
                if model.failed { CommunityFailure { model.reload(recent: recent) } } else { CommunitySkeleton(rows: 6) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(model.apps) { app in
                        Button { open(app.url) } label: { tile(app) }.buttonStyle(.plain)
                    }
                }
                if model.failed { CommunityFailure { model.more() } }
                else if model.canLoadMore { CommunityMoreButton(busy: model.loading) { model.more() } }
            }
        }
        .task(id: recent) { model.reload(recent: recent) }
        .onDisappear { model.cancel() }
    }

    private func tile(_ app: CommunityHomeParser.WorkshopApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CommunityThumb(url: app.logo ?? app.preview, aspect: 184.0 / 69, radius: 4)
            HStack(alignment: .firstTextBaseline) {
                Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(app.items).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
