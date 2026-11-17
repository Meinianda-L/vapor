import Foundation

/// steamcommunity.com/id/<name> → steamID64, through the profile's public XML view.
public enum VanityResolver {
    /// nil for Steam's error answer ("The specified profile could not be found") or anything that is not a profile.
    public static func steamID(xml: String) -> String? {
        xml.firstMatch(#"<steamID64>\s*(\d{17})\s*</steamID64>"#)?[1]
    }

    public static func url(_ name: String) -> URL? {
        var c = URLComponents(string: "https://steamcommunity.com")
        c?.percentEncodedPath = "/id/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name) + "/"
        c?.queryItems = [URLQueryItem(name: "xml", value: "1")]
        return c?.url
    }

    /// Cached for an hour by the client's fetch cache; names rarely move.
    public static func resolve(_ name: String) async throws -> String? {
        guard let url = url(name) else { return nil }
        return steamID(xml: try await CommunityClient.fetchString(url, ttl: 3600))
    }
}
