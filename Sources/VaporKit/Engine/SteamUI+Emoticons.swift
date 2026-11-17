import Foundation

/// The signed-in user's emoticons and stickers, from the chat's own EmoticonStore (what Steam's picker shows).
/// Picking one sends what Steam's picker sends: ":name:" in the text, or a "/sticker <name>" message; the chat
/// server turns both into BBCode.
extension SteamUI {
    public struct EmoticonList: Equatable, Sendable, Decodable {
        public struct Item: Equatable, Sendable, Decodable, Identifiable {
            public let name: String
            /// The game it came from (stickers).
            public let appid: UInt32?
            public let lastUsed: Int
            public var id: String { name }
        }
        public let emoticons: [Item]
        public let stickers: [Item]
        /// Most recently used emoticon names first.
        public let recent: [String]

        public init(emoticons: [Item] = [], stickers: [Item] = [], recent: [String] = []) {
            self.emoticons = emoticons; self.stickers = stickers; self.recent = recent
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            emoticons = (try? c.decode([Item].self, forKey: .emoticons)) ?? []
            stickers = (try? c.decode([Item].self, forKey: .stickers)) ?? []
            recent = (try? c.decode([String].self, forKey: .recent)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case emoticons, stickers, recent }
    }

    public func emoticonList() async throws -> EmoticonList {
        let data = try await evaluate("""
            const es = window.g_FriendsUIApp?.ChatStore?.EmoticonStore;
            if (!es) return null;
            // Steam asks the server for the list the first time its picker opens; so do we.
            if (!es.m_bEmoticonListRequested) es.RequestEmoticonList();
            for (let i = 0; i < 40 && !(es.emoticon_list?.length); i++) await new Promise(r => setTimeout(r, 250));
            const item = x => ({ name: String(x.name || ''), appid: x.appid ? Number(x.appid) : null,
                                 lastUsed: Number(x.last_used || x.time_last_used || 0) });
            return {
              emoticons: (es.emoticon_list || []).map(item).filter(x => x.name),
              stickers: (es.GetStickerList?.() || es.m_rgStickers || []).map(item).filter(x => x.name),
              recent: (es.recent_emoticons || []).map(x => String(x.name || '')).filter(Boolean),
            };
            """)
        return (try? JSONDecoder().decode(EmoticonList?.self, from: data)).flatMap { $0 } ?? EmoticonList()
    }
}
