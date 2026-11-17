import Foundation

public struct TradeOffer: Identifiable, Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let image: URL?
        public let title: String
    }
    public struct Side: Sendable, Equatable {
        public let header: String
        public let items: [Item]
    }

    public let id: String
    public let partner: String
    /// steamID64, from the profile link or mini-profile id.
    public let partnerID: String?
    public let avatar: URL?
    public let message: String
    /// "已取消", "已接受" … for offers that are no longer open; nil while it can still be answered.
    public let status: String?
    public let sides: [Side]
}

public struct TradeOfferList: Sendable, Equatable {
    public var offers: [TradeOffer]
    /// Steam's own sentence when there are none.
    public var emptyNote: String?
}

/// steamcommunity.com/profiles/<id>/tradeoffers[/sent]: the web page is the only place a client session can
/// read offers (IEconService needs an API key), so this is read-only HTML.
public enum TradeOfferParser {
    public static func list(html: String) -> TradeOfferList {
        let root = HTML.parse(html)
        let base = URL(string: "https://steamcommunity.com/")
        var offers: [TradeOffer] = []
        for node in root.all(class: "tradeoffer") {
            guard let id = node.attr("id")?.replacingOccurrences(of: "tradeofferid_", with: ""), !id.isEmpty, id.allSatisfy(\.isNumber) else { continue }
            let partnerBlock = node.first(class: "tradeoffer_partner")
            let avatarNode = partnerBlock?.first(class: "playerAvatar")
            var partnerID: String?
            if let account = avatarNode?.attr("data-miniprofile").flatMap(UInt64.init) { partnerID = String(76_561_197_960_265_728 + account) }
            let header = node.first(class: "tradeoffer_header")?.plainText ?? ""
            let sides: [TradeOffer.Side] = node.all(class: "tradeoffer_items").map { side in
                let items: [TradeOffer.Item] = side.all(class: "trade_item").map { item in
                    let img = item.first(tag: "img")
                    return TradeOffer.Item(image: img?.attr("src").flatMap { RichText.resolve($0, base: base) },
                                           title: img?.attr("alt") ?? item.attr("title") ?? "")
                }
                return TradeOffer.Side(header: side.first(class: "tradeoffer_items_header")?.plainText ?? "", items: items)
            }
            let banner = node.first(class: "tradeoffer_items_banner")?.plainText
            offers.append(TradeOffer(id: id, partner: header, partnerID: partnerID,
                                     avatar: avatarNode?.first(tag: "img")?.attr("src").flatMap { RichText.resolve($0, base: base) },
                                     message: node.first(class: "tradeoffer_message")?.plainText ?? "",
                                     status: (banner?.isEmpty == false) ? banner : nil, sides: sides))
        }
        let note = root.first(class: "tradeoffer_welcome_ctn")?.first(tag: "h2")?.plainText
        return TradeOfferList(offers: offers, emptyNote: offers.isEmpty ? note : nil)
    }
}
