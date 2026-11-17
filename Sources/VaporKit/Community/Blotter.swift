import Foundation

// The signed-in user's friend activity ("blotter") from steamcommunity.com/profiles/<id64>/home/.

public struct ActivityEvent: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case status, screenshot, workshop, review, achievement, purchase, playing, other }
    public let id: String
    public let kind: Kind
    public let day: String
    public let author: String
    public let authorURL: URL?
    public let avatar: URL?
    public let text: String
    public let image: URL?
    public let link: URL?
    public let appid: UInt32?
}

public enum BlotterParser {
    static func kind(of classes: String) -> ActivityEvent.Kind {
        let c = classes.lowercased()
        if c.contains("screenshot") { return .screenshot }
        if c.contains("workshop") || c.contains("sharedfile") { return .workshop }
        if c.contains("recommendation") || c.contains("review") { return .review }
        if c.contains("achievement") { return .achievement }
        if c.contains("purchase") || c.contains("gamepurchase") { return .purchase }
        if c.contains("playing") || c.contains("gameplay") { return .playing }
        if c.contains("userstatus") || c.contains("status") { return .status }
        return .other
    }

    public static func events(html: String, limit: Int = 60) -> [ActivityEvent] {
        let root = HTML.parse(html)
        var out: [ActivityEvent] = []
        var n = 0
        for day in root.all(class: "blotter_day") {
            let dayText = day.first(class: "blotter_day_header")?.plainText ?? ""
            for block in day.all(class: "blotter_block") {
                let author = block.first(class: "blotter_author_block")
                let name = author?.first { $0.name == "a" && !$0.plainText.isEmpty && $0.first(tag: "img") == nil }?.plainText
                    ?? block.first(class: "whiteLink")?.plainText ?? ""
                let avatar = CommunityParsers.imageURL(in: author?.first(class: "playerAvatar") ?? author)
                var text = block.plainText
                if !name.isEmpty, text.hasPrefix(name) { text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) }
                guard !text.isEmpty || !name.isEmpty else { continue }
                let picture = block.all(tag: "img").compactMap { $0.attr("src") }.first { $0.contains("steamusercontent") || $0.contains("/economy/image/") || $0.contains("ugc") }
                let link = block.all(tag: "a").compactMap { CommunityParsers.url($0.attr("href")) }
                    .first { $0.path.contains("/filedetails") || $0.path.contains("/app/") || $0.path.contains("/recommended/") }
                let appid = link.flatMap { $0.path.firstMatch(#"/app/(\d+)"#)?[1] }.flatMap(UInt32.init)
                n += 1
                out.append(ActivityEvent(id: "\(n)", kind: kind(of: block.attr("class") ?? ""), day: dayText, author: name,
                                         authorURL: CommunityParsers.url(author?.first(tag: "a")?.attr("href")), avatar: avatar,
                                         text: String(text.prefix(260)), image: picture.flatMap(CommunityParsers.url), link: link, appid: appid))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

public extension CommunityHomeClient {
    static func activity(steamID: String) -> URL { URL(string: "https://steamcommunity.com/profiles/\(steamID)/home/?l=schinese")! }
}
