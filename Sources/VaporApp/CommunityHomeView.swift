import SwiftUI
import VaporKit

/// Steam's top-level 社区: home feed, general forums, workshop front, market and friend activity.
struct CommunityHomeView: View {
    var open: (URL) -> Void
    var openApp: (UInt32) -> Void

    enum Section: CaseIterable, Hashable {
        case home, discussions, workshop, market, activity
        var title: String {
            switch self {
            case .home: return String(localized: "主页")
            case .discussions: return String(localized: "讨论")
            case .workshop: return String(localized: "创意工坊")
            case .market: return String(localized: "市场")
            case .activity: return String(localized: "动态")
            }
        }
    }

    @State private var section: Section

    init(open: @escaping (URL) -> Void, openApp: @escaping (UInt32) -> Void, section: Section = .home) {
        self.open = open; self.openApp = openApp
        _section = State(initialValue: section)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("社区").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 22) {
                        ForEach(Section.allCases, id: \.self) { s in
                            Button { section = s } label: {
                                Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(section == s ? Theme.accent : Theme.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().overlay(Theme.hairline)
                }
                switch section {
                case .home: CommunityHomeFeed(open: open, openApp: openApp)
                case .discussions: CommunityForumsTab(open: open)
                case .workshop: CommunityWorkshopTab(open: open)
                case .market: CommunityMarketTab()
                case .activity: CommunityActivityTab(open: open, openApp: openApp)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .environment(\.openURL, OpenURLAction { url in
            guard communityWeb(url) else { return .discarded }
            open(url)
            return .handled
        })
    }
}

// MARK: - Shared

/// Places each child in the shortest column, so cards of different heights pack without gaps.
struct CommunityMasonry: Layout {
    var minColumn: CGFloat = 240
    var spacing: CGFloat = 16

    private func columns(for width: CGFloat) -> Int { max(1, Int((width + spacing) / (minColumn + spacing))) }

    private func place(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let n = columns(for: width)
        let colWidth = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = [CGFloat](repeating: 0, count: n)
        var frames: [CGRect] = []
        for sub in subviews {
            let col = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let h = sub.sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height
            frames.append(CGRect(x: CGFloat(col) * (colWidth + spacing), y: heights[col], width: colWidth, height: h))
            heights[col] += h + spacing
        }
        return (frames, max(0, (heights.max() ?? spacing) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = place(subviews, width: bounds.width)
        for (sub, f) in zip(subviews, laid.frames) {
            sub.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// Button row used under lists that load in pages.
struct CommunityMoreButton: View {
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(busy ? String(localized: "载入中…") : String(localized: "查看更多")).font(.system(size: 12.5)).foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain).disabled(busy).padding(.vertical, 8)
    }
}

struct CommunityFailure: View {
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text("没有加载出来。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Button("重试", action: retry).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
        }
    }
}

/// A small pill-less filter row: the selected word is lit, the rest grey.
struct CommunityChips<Tag: Hashable>: View {
    let items: [(Tag, String)]
    @Binding var selection: Tag
    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { selection = item.0 } label: {
                    Text(item.1).font(.system(size: 12.5, weight: selection == item.0 ? .semibold : .regular))
                        .foregroundStyle(selection == item.0 ? Theme.text : Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
