import Foundation

/// What Steam's own profile editor shows and saves (steamcommunity.com/profiles/<id>/edit/info).
public struct ProfileEditData: Sendable, Equatable {
    public var personaName = ""
    public var customURL = ""
    public var realName = ""
    public var summary = ""
    public var countryCode = ""
    public var stateCode = ""
    public var cityCode = ""
    public var hideProfileAwards = false
    public var countryName = ""
    public var stateName = ""
    public var cityName = ""

    /// The editor page carries the current values as JSON in `data-profile-edit`.
    public static func parse(html: String) -> ProfileEditData? {
        guard let node = HTML.parse(html).first(where: { $0.attr("data-profile-edit") != nil }),
              let raw = node.attr("data-profile-edit"),
              let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let loc = o["LocationData"] as? [String: Any] ?? [:]
        let prefs = o["ProfilePreferences"] as? [String: Any] ?? [:]
        func text(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        return ProfileEditData(personaName: text(o, "strPersonaName"), customURL: text(o, "strCustomURL"), realName: text(o, "strRealName"),
                               summary: text(o, "strSummary"), countryCode: text(loc, "locCountryCode"), stateCode: text(loc, "locStateCode"),
                               cityCode: text(loc, "locCityCode"), hideProfileAwards: (prefs["hide_profile_awards"] as? Int ?? 0) != 0,
                               countryName: text(loc, "locCountry"), stateName: text(loc, "locState"), cityName: text(loc, "locCity"))
    }
}

public struct LocationOption: Sendable, Equatable, Identifiable, Hashable {
    public let code: String
    public let name: String
    public var hasChildren = false
    public var id: String { code }

    public init(code: String, name: String, hasChildren: Bool = false) { self.code = code; self.name = name; self.hasChildren = hasChildren }
}

public enum ProfileEditParsers {
    /// `actions/QueryLocations/`: countries; `…/<country>`: states; `…/<country>/<state>`: cities.
    public static func locations(json data: Data) -> [LocationOption] {
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return rows.compactMap { r in
            if let c = r["countrycode"] as? String, r["statecode"] == nil, r["cityid"] == nil, let n = r["countryname"] as? String {
                return LocationOption(code: c, name: n, hasChildren: (r["hasstates"] as? Int ?? 0) != 0)
            }
            if let c = r["statecode"] as? String, let n = r["statename"] as? String { return LocationOption(code: c, name: n, hasChildren: true) }
            if let c = r["cityid"], let n = r["cityname"] as? String { return LocationOption(code: "\(c)", name: n) }
            return nil
        }
    }

    /// The saving endpoint's answer: nil when accepted, else the message Steam gives (HTML-free).
    public static func saveError(json data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Steam 没有正常回应。" }
        if (o["success"] as? Int) == 1 || (o["success"] as? Bool) == true { return nil }
        let message = HTML.parse(o["errmsg"] as? String ?? "").plainText
        return message.isEmpty ? "Steam 没有保存这些更改。" : message
    }
}

public enum ProfileEditClient {
    public static func locationURL(_ path: String = "") -> URL { URL(string: "https://steamcommunity.com/actions/QueryLocations/\(path)")! }

    public static func load(steamID: String, cookie: String) async throws -> ProfileEditData {
        let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)/edit/info?l=schinese")!
        guard let data = ProfileEditData.parse(html: try await CommunityClient.fetchString(url, cookie: cookie, ttl: 0)) else { throw URLError(.cannotParseResponse) }
        return data
    }

    public static func locations(_ path: String = "") async throws -> [LocationOption] {
        ProfileEditParsers.locations(json: try await CommunityClient.fetch(locationURL(path), ttl: 86_400))
    }

    /// Saves the profile as Steam's editor does. `cookie` is the web session; its `sessionid` is the CSRF token.
    public static func save(_ edit: ProfileEditData, steamID: String, cookie: String) async throws {
        let session = cookie.split(separator: ";").compactMap { part -> String? in
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 && kv[0] == "sessionid" ? kv[1] : nil
        }.first
        guard let session else { throw CommentClient.PostFailure(reason: "网页登录还没有就绪，请稍后再试。") }
        var request = URLRequest(url: URL(string: "https://steamcommunity.com/profiles/\(steamID)/edit/")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://steamcommunity.com", forHTTPHeaderField: "Origin")
        request.setValue("https://steamcommunity.com/profiles/\(steamID)/edit/info", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        var fields: [(String, String)] = [
            ("sessionID", session), ("type", "profileSave"), ("json", "1"),
            ("personaName", edit.personaName), ("real_name", edit.realName), ("customURL", edit.customURL),
            ("country", edit.countryCode), ("state", edit.stateCode), ("city", edit.cityCode), ("summary", edit.summary),
            ("hide_profile_awards", edit.hideProfileAwards ? "1" : "0"),
        ]
        for n in 1...3 { fields += [("weblink_\(n)_title", ""), ("weblink_\(n)_url", "")] }
        request.httpBody = Data(WebForm.encode(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CommentClient.PostFailure(reason: "Steam 没有正常回应。") }
        if let reason = ProfileEditParsers.saveError(json: data) { throw CommentClient.PostFailure(reason: reason) }
    }
}
