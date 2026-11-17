import Foundation

/// What the Steam client's library app page shows, read from the same stores its sections use:
/// appDetailsStore (play bar), Player.GetFriendsGameplayInfo + friendStore (好友), appActivityStore
/// (动态: partner events, your unlocks, friends' posts), badgeStore (集换式卡牌), appReviewStore
/// (your review), SteamClient.GameNotes (笔记). Screenshots are read from Steam's userdata folder.
extension SteamUI {
    // MARK: - Play bar and page facts

    public struct LogoPosition: Sendable, Equatable {
        public enum Pin: String, Sendable { case bottomLeft = "BottomLeft", upperLeft = "UpperLeft", centerCenter = "CenterCenter",
                                                 upperCenter = "UpperCenter", bottomCenter = "BottomCenter" }
        public let pin: Pin
        /// The box the logo is fitted into, in percent of the hero's width and height.
        public let widthPct: Double
        public let heightPct: Double
    }

    public struct AppPageInfo: Sendable, Equatable {
        /// steamui's ECloudStatus: 0/2 unknown, 1 disabled, 3 synchronized, 4 checking, 5 out of sync,
        /// 6 uploading, 7 downloading, 8 sync failed, 9 conflict, 10 pending elsewhere.
        public let cloudStatus: Int
        public let cloudProgress: Int
        public let cloudAvailable: Bool
        public let playtimeMinutes: Int
        public let playtimeTwoWeeks: Int
        public let lastPlayed: Date?
        public let screenshots: Int
        public let workshopVisible: Bool
        public let marketPresence: Bool
        public let developer: String
        public let homepage: URL?
        public let manual: URL?
        public let releaseDate: Date?
        public let isSoftware: Bool
        public let logo: LogoPosition?
    }

    public func appPageInfo(_ appid: UInt32) async throws -> AppPageInfo? {
        Self.parseAppPageInfo(try await appPage("info(\(appid))"))
    }

    // MARK: - Friends who play

    public struct AppFriend: Sendable, Equatable, Identifiable {
        public let steamID: String
        public let name: String
        public let avatar: URL?
        public let state: Int
        public let gameAppID: UInt32
        public let minutesRecent: Int
        public let minutesForever: Int
        public var id: String { steamID }
    }

    /// Steam's four groups: playing now, played in the last two weeks, played before, wishlisted.
    public struct AppFriends: Sendable, Equatable {
        public let inGame: [AppFriend]
        public let recent: [AppFriend]
        public let ever: [AppFriend]
        public let wishlist: [AppFriend]
        public var isEmpty: Bool { inGame.isEmpty && recent.isEmpty && ever.isEmpty && wishlist.isEmpty }
    }

    public func appFriends(_ appid: UInt32) async throws -> AppFriends {
        Self.parseAppFriends(try await appPage("friends(\(appid))"))
    }

    // MARK: - Activity feed

    public struct AppActivity: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case achievement, event, firstPlayed, status, review, receivedGame, cards, other }
        public struct Unlock: Sendable, Equatable { public let name: String; public let description: String; public let icon: URL?; public let time: Date? }
        public struct Event: Sendable, Equatable {
            public let gid: String
            public let title: String
            public let summary: String
            /// EProtoClanEventType; Steam labels it with `PartnerEvent_<type>`.
            public let type: Int
            public let image: URL?
        }
        public let id: String
        public let kind: Kind
        public let time: Date
        public let actor: AppFriend?
        public let isSelf: Bool
        public let unlocks: [Unlock]
        public let event: Event?
        public let text: String
        public let count: Int
        public let votedUp: Bool?
    }

    /// Newest first, as appActivityStore keeps it (fetched and cached by the client itself).
    public func appActivity(_ appid: UInt32, limit: Int = 40) async throws -> [AppActivity] {
        Self.parseAppActivity(try await appPage("activity(\(appid), \(limit))"))
    }

    // MARK: - Trading cards

    public struct AppBadge: Sendable, Equatable {
        public struct Card: Sendable, Equatable, Identifiable {
            public let name: String
            public let title: String
            public let image: URL?
            public let owned: Int
            public var id: String { name }
        }
        public let name: String
        public let icon: URL?
        public let level: Int
        public let maxLevel: Int
        public let xp: Int
        public let maxed: Bool
        public let nextLevelName: String
        public let nextLevelXP: Int
        public let cards: [Card]
        public var missing: Int { maxed ? 0 : cards.filter { $0.owned == 0 }.count }
    }

    /// Nil for games without trading cards (or when the community did not answer).
    public func appBadge(_ appid: UInt32) async throws -> AppBadge? {
        Self.parseAppBadge(try await appPage("badge(\(appid))"))
    }

    // MARK: - Your review

    public struct AppReview: Sendable, Equatable {
        public let id: String
        public let votedUp: Bool
        public let text: String
        public let playtimeAtReview: Int
        public let votesUp: Int
        public let comments: Int
        public let language: String
        public let isPublic: Bool
    }

    public enum AppReviewState: Sendable, Equatable { case none, reviewed(AppReview) }

    public func myReview(_ appid: UInt32) async throws -> AppReviewState {
        Self.parseReviewState(try await appPage("review(\(appid))"))
    }

    /// What the client's review dialog sends: a revision goes to UserReviews.Update, a new review is
    /// posted to the store's recommendgame form with the client's cookies.
    public func submitReview(_ appid: UInt32, votedUp: Bool, text: String, isPublic: Bool, allowComments: Bool,
                             revising previous: AppReview?) async throws {
        var body: [String: Any] = ["appid": appid, "up": votedUp, "text": text, "isPublic": isPublic, "allowComments": allowComments]
        if let previous { body["previous"] = previous.id; body["language"] = previous.language }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        _ = try await appPage("submitReview(\(json))")
    }

    // MARK: - Notes

    public struct AppNote: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// BBCode, as Steam's notes editor writes it.
        public let content: String
        public let modified: Date?
    }

    public func appNotes(_ appid: UInt32) async throws -> [AppNote] {
        Self.parseNotes(try await appPage("notes(\(appid))"))
    }

    /// Updates the note with `id`, or adds a new one when `id` is nil, then syncs to Steam Cloud the way
    /// the client's editor does. Returns the note's id.
    @discardableResult
    public func saveAppNote(_ appid: UInt32, id: String?, title: String, content: String) async throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["id": id ?? NSNull(), "title": title, "content": content] as [String: Any]), as: UTF8.self)
        let data = try await appPage("saveNote(\(appid), \(json))")
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String ?? ""
    }

    // MARK: - Screenshots

    /// Local screenshots for the app, newest first: Steam keeps them (and thumbnails) under
    /// userdata/<account id>/760/remote/<appid>/screenshots.
    public static func localScreenshots(steamRoot: URL, steamID64: String, appid: UInt32) -> [URL] {
        guard let id = UInt64(steamID64), id > 76_561_197_960_265_728 else { return [] }
        let dir = steamRoot.appendingPathComponent("userdata/\(id - 76_561_197_960_265_728)/760/remote/\(appid)/screenshots")
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        let shots = files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return shots.sorted { date($0) > date($1) }.map { shot in
            let thumb = dir.appendingPathComponent("thumbnails").appendingPathComponent(shot.lastPathComponent)
            return fm.fileExists(atPath: thumb.path) ? thumb : shot
        }
    }

    // MARK: - Transport

    private func appPage(_ call: String) async throws -> Data {
        try await evaluate("\(Self.storeKit)\n\(Self.appPageKit)\nreturn await window.__vaporAppPage.\(call);")
    }

    static let appPageKitVersion = 1

    static let appPageKit = #"""
    if (window.__vaporAppPage?.version !== \#(appPageKitVersion)) window.__vaporAppPage = (() => {
      const num = v => Number(v ?? 0) || 0;
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const g = f => { try { return f(); } catch { return undefined; } };
      const details = appid => new Promise(resolve => {
        const cached = g(() => appDetailsStore.GetAppDetails(appid));
        if (cached) return resolve(cached);
        let h = null;
        const timer = setTimeout(() => { h?.unregister(); resolve(null); }, 6000);
        h = SteamClient.Apps.RegisterForAppDetails(appid, d => { clearTimeout(timer); h?.unregister(); resolve(d); });
      });
      const who = f => {
        const p = f?.persona;
        if (!p) return null;
        return { steamID: String(f.steamid64 ?? g(() => p.m_steamid.ConvertTo64BitString()) ?? ''), name: f.display_name || p.m_strPlayerName || '',
                 avatar: g(() => p.BHasAvatarSet()) === false ? null : (p.avatar_url_medium || null), state: num(p.m_ePersonaState),
                 gameAppID: num(p.m_unGamePlayedAppID) };
      };
      const self = () => g(() => friendStore.currentUserSteamID.ConvertTo64BitString()) || '';
      const notesFile = appid => [`notes_${appid}`, `notes_${appid}_images/`];
      const readNotes = async appid => {
        const r = await SteamClient.GameNotes.GetNotes(...notesFile(appid));
        if (r?.result === 9) return [];                  // no notes file yet
        if (r?.result !== 1) throw new Error('GameNotes.GetNotes: EResult ' + r?.result);
        return JSON.parse(r.notes || '{}').notes || [];
      };
      return {
        version: \#(appPageKitVersion),
        async info(appid) {
          const d = await details(appid);
          if (!d) return null;
          const o = g(() => appStore.GetAppOverviewByAppID(appid));
          const pos = d.libraryAssets?.logoPosition;
          return { cloudStatus: num(d.eCloudStatus), cloudProgress: num(d.nCloudProgressPercent),
            cloudAvailable: !!d.bCloudAvailable && !!d.bCloudEnabledForAccount, playtimeMinutes: num(d.nPlaytimeForever),
            playtimeTwoWeeks: num(o?.minutes_playtime_last_two_weeks), lastPlayed: num(d.rtLastTimePlayed), screenshots: num(d.nScreenshots),
            workshopVisible: !!d.bWorkshopVisible, marketPresence: !!d.bCommunityMarketPresence, developer: d.strDeveloperName || '',
            homepage: d.strHomepageURL || '', manual: d.strManualURL || '',
            releaseDate: num(o?.rt_original_release_date) || num(o?.rt_steam_release_date),
            isSoftware: !!g(() => o.BIsApplicationOrTool()),
            logo: pos ? { position: pos.pinnedPosition || '', widthPct: num(pos.nWidthPct), heightPct: num(pos.nHeightPct) } : null };
        },
        async friends(appid) {
          const r = await window.__vaporStore.call('Player', 'GetFriendsGameplayInfo', { appid });
          const all = new Map((g(() => friendStore.m_FriendsUIFriendStore.all_friends) || []).map(f => [String(f.steamid64), f]));
          const times = new Map();
          for (const x of [...(r.in_game || []), ...(r.played_recently || []), ...(r.played_ever || []), ...(r.in_wishlist || [])])
            if (!times.has(String(x.steamid))) times.set(String(x.steamid), x);
          const row = f => {
            const p = f && !f.is_blocked ? who(f) : null;
            if (!p) return null;
            const t = times.get(p.steamID);
            return { ...p, minutesRecent: num(t?.minutes_played), minutesForever: num(t?.minutes_played_forever) };
          };
          const list = xs => (xs || []).map(x => row(all.get(String(x.steamid)))).filter(Boolean);
          // Like the client: whoever is in this game right now, by presence, then the server's groups.
          const inGame = [...all.values()].filter(f => num(f.persona?.m_unGamePlayedAppID) === appid).map(row).filter(Boolean);
          const playing = new Set(inGame.map(f => f.steamID));
          const others = xs => list(xs).filter(f => !playing.has(f.steamID));
          return { inGame, recent: [...others(r.in_game), ...others(r.played_recently)], ever: others(r.played_ever), wishlist: others(r.in_wishlist) };
        },
        async activity(appid, limit) {
          let a = appActivityStore.GetAppActivity(appid);
          for (let i = 0; !a && i < 40; i++) { await sleep(250); a = appActivityStore.GetAppActivity(appid); }
          if (!a) return [];
          const me = self(), out = [];
          const kinds = { 2: 'achievement', 3: 'receivedGame', 10: 'review', 16: 'status', 30: 'firstPlayed', 1002: 'event' };
          for (const day of a.appActivityByDay || []) for (const e of day.m_rgEvents || []) {
            if (out.length >= limit) return out;
            const kind = e.bIsGameActivity ? (e.m_rgTradingCards ? 'cards' : 'other') : (kinds[e.eEventType] || 'other');
            const actor = kind === 'event' ? null : who(g(() => friendStore.GetFriendState(e.steamIDActor)));
            const p = e.preview;
            out.push({ id: `${e.eEventType ?? 'g' + e.eGameActivityType}-${e.unUniqueID ?? ''}-${e.rtEventTime}`, kind, time: num(e.rtEventTime),
              actor, isSelf: !!actor && actor.steamID === me,
              unlocks: (e.m_rgAchievements || []).map(x => ({ name: x.strName || '', description: x.strDescription || '', icon: x.strImage || null, time: num(x.rtUnlocked) })),
              event: p ? { gid: String(p.gidAnnouncement || p.gid || ''), title: p.strTitle || '', summary: p.strSummary || '', type: num(p.eType),
                           image: (p.rgCapsuleImages || [])[0] || null } : null,
              text: g(() => e.GetUserStatus().statusText) || '', count: (e.m_cardAssetIDs || e.m_rgAppIds || []).length,
              votedUp: g(() => e.GetRecommendationDetails()?.voted_up) ?? null });
          }
          return out;
        },
        async badge(appid) {
          if (typeof badgeStore === 'undefined') return null;
          let b = badgeStore.GetBadgeData(appid);
          for (let i = 0; !b?.rgCards && i < 24; i++) { await sleep(250); b = badgeStore.GetBadgeData(appid); }
          if (!b?.rgCards?.length) return null;
          return { name: b.strName || '', icon: b.nLevel > 0 ? b.strIconURL || null : null, level: num(b.nLevel), maxLevel: num(b.nMaxLevel),
            xp: num(b.nXP), maxed: !!b.bMaxed, nextLevelName: b.strNextLevelName || '', nextLevelXP: num(b.nNextLevelXP),
            cards: b.rgCards.map(c => ({ name: c.strName || '', title: c.strTitle || '', image: c.strImgURL || null, owned: num(c.nOwned) })) };
        },
        async review(appid) {
          const r = await appReviewStore.GetReview(appid, false);
          return { review: r ? { id: String(r.recommendationid || ''), votedUp: !!r.voted_up, text: r.review || '', playtimeAtReview: num(r.playtime_at_review),
            votesUp: num(r.votes_up), comments: num(r.comment_count), language: r.language || '', isPublic: r.is_public !== false } : null };
        },
        async submitReview(o) {
          if (o.previous) {
            await window.__vaporStore.call('UserReviews', 'Update', { recommendationid: o.previous, review_text: o.text, voted_up: o.up,
              is_public: o.isPublic, language: o.language, received_compensation: false, comments_disabled: !o.allowComments });
          } else {
            const f = new FormData();
            for (const [k, v] of Object.entries({ appid: o.appid, comment: o.text, rated_up: o.up, is_public: o.isPublic, disable_comments: !o.allowComments,
                                                  received_compensation: false, saved_hardware_id: undefined, steamworksappid: o.appid, hide_in_steam_china: true }))
              f.append(k, String(v));
            const r = await (await fetch('https://store.steampowered.com/friends/recommendgame', { method: 'POST', body: f, credentials: 'include' })).json();
            if (!r?.success) throw new Error(r?.strError || 'recommendgame failed');
          }
          g(() => appReviewStore.GetReview(o.appid, true));
          return true;
        },
        async notes(appid) {
          return (await readNotes(appid)).map(n => ({ id: String(n.id || ''), title: n.title || '', content: n.content || '', modified: num(n.time_modified) }));
        },
        async saveNote(appid, o) {
          const notes = await readNotes(appid), now = Math.floor(Date.now() / 1000);
          let note = o.id && notes.find(n => n.id === o.id);
          if (note) Object.assign(note, { title: o.title, content: o.content, time_modified: now });
          else notes.push(note = { id: Date.now().toString(36), appid, ordinal: 0, time_created: now, time_modified: now, title: o.title, content: o.content });
          const r = await SteamClient.GameNotes.SaveNotes(notesFile(appid)[0], JSON.stringify({ notes }));
          if (r !== 1) throw new Error('GameNotes.SaveNotes: EResult ' + r);
          await SteamClient.GameNotes.SyncToServer();
          return note.id;
        },
      };
    })();
    """#
}

// MARK: - Parsing (pure, from the kit's JSON)

extension SteamUI {
    private static func root(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
    private static func string(_ any: Any?) -> String { any as? String ?? "" }
    private static func bool(_ any: Any?) -> Bool { (any as? Bool) ?? ((any as? NSNumber)?.boolValue ?? false) }
    private static func link(_ any: Any?) -> URL? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return URL(string: s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : s)
    }

    static func parseAppPageInfo(_ data: Data) -> AppPageInfo? {
        guard let d = root(data) as? [String: Any] else { return nil }
        let logo = (d["logo"] as? [String: Any]).flatMap { l -> LogoPosition? in
            guard let pin = LogoPosition.Pin(rawValue: string(l["position"])) else { return nil }
            return LogoPosition(pin: pin, widthPct: Double(int(l["widthPct"])), heightPct: Double(int(l["heightPct"])))
        }
        return AppPageInfo(cloudStatus: Int(int(d["cloudStatus"])), cloudProgress: Int(int(d["cloudProgress"])), cloudAvailable: bool(d["cloudAvailable"]),
                           playtimeMinutes: Int(int(d["playtimeMinutes"])), playtimeTwoWeeks: Int(int(d["playtimeTwoWeeks"])),
                           lastPlayed: date(d["lastPlayed"]), screenshots: Int(int(d["screenshots"])), workshopVisible: bool(d["workshopVisible"]),
                           marketPresence: bool(d["marketPresence"]), developer: string(d["developer"]), homepage: link(d["homepage"]),
                           manual: link(d["manual"]), releaseDate: date(d["releaseDate"]), isSoftware: bool(d["isSoftware"]), logo: logo)
    }

    private static func friend(_ any: Any?) -> AppFriend? {
        guard let f = any as? [String: Any], !string(f["steamID"]).isEmpty else { return nil }
        return AppFriend(steamID: string(f["steamID"]), name: string(f["name"]), avatar: link(f["avatar"]), state: Int(int(f["state"])),
                         gameAppID: UInt32(clamping: int(f["gameAppID"])), minutesRecent: Int(int(f["minutesRecent"])),
                         minutesForever: Int(int(f["minutesForever"])))
    }

    static func parseAppFriends(_ data: Data) -> AppFriends {
        let d = root(data) as? [String: Any] ?? [:]
        func list(_ key: String) -> [AppFriend] { (d[key] as? [Any] ?? []).compactMap(friend) }
        return AppFriends(inGame: list("inGame"), recent: list("recent"), ever: list("ever"), wishlist: list("wishlist"))
    }

    static func parseAppActivity(_ data: Data) -> [AppActivity] {
        (root(data) as? [[String: Any]] ?? []).compactMap { e in
            guard let time = date(e["time"]) else { return nil }
            let event = (e["event"] as? [String: Any]).map {
                AppActivity.Event(gid: string($0["gid"]), title: string($0["title"]), summary: string($0["summary"]),
                                  type: Int(int($0["type"])), image: link($0["image"]))
            }
            let unlocks = (e["unlocks"] as? [[String: Any]] ?? []).map {
                AppActivity.Unlock(name: string($0["name"]), description: string($0["description"]), icon: link($0["icon"]), time: date($0["time"]))
            }
            return AppActivity(id: string(e["id"]), kind: AppActivity.Kind(rawValue: string(e["kind"])) ?? .other, time: time,
                               actor: friend(e["actor"]), isSelf: bool(e["isSelf"]), unlocks: unlocks, event: event,
                               text: string(e["text"]), count: Int(int(e["count"])), votedUp: e["votedUp"] as? Bool)
        }
    }

    static func parseAppBadge(_ data: Data) -> AppBadge? {
        guard let b = root(data) as? [String: Any] else { return nil }
        let cards = (b["cards"] as? [[String: Any]] ?? []).map {
            AppBadge.Card(name: string($0["name"]), title: string($0["title"]), image: link($0["image"]), owned: Int(int($0["owned"])))
        }
        guard !cards.isEmpty else { return nil }
        return AppBadge(name: string(b["name"]), icon: link(b["icon"]), level: Int(int(b["level"])), maxLevel: Int(int(b["maxLevel"])),
                        xp: Int(int(b["xp"])), maxed: bool(b["maxed"]), nextLevelName: string(b["nextLevelName"]),
                        nextLevelXP: Int(int(b["nextLevelXP"])), cards: cards)
    }

    static func parseReviewState(_ data: Data) -> AppReviewState {
        guard let r = (root(data) as? [String: Any])?["review"] as? [String: Any] else { return .none }
        return .reviewed(AppReview(id: string(r["id"]), votedUp: bool(r["votedUp"]), text: string(r["text"]),
                                   playtimeAtReview: Int(int(r["playtimeAtReview"])), votesUp: Int(int(r["votesUp"])),
                                   comments: Int(int(r["comments"])), language: string(r["language"]), isPublic: bool(r["isPublic"])))
    }

    static func parseNotes(_ data: Data) -> [AppNote] {
        (root(data) as? [[String: Any]] ?? []).compactMap { n in
            guard !string(n["id"]).isEmpty else { return nil }
            return AppNote(id: string(n["id"]), title: string(n["title"]), content: string(n["content"]), modified: date(n["modified"]))
        }
    }
}
