import Foundation

/// Community features that Steam's client answers itself: the points balance and redeeming, and the
/// workshop subscription list. They use the same service connection as the native store (`storeCall`).
extension SteamUI {
    // MARK: - Points

    public struct PointsSummary: Sendable, Equatable {
        public let points: Int64
        public let earned: Int64
        public let spent: Int64
    }

    /// The signed-in account's points balance. Read-only.
    public func pointsSummary() async throws -> PointsSummary {
        Self.parsePoints(try await storeCall("LoyaltyRewards", "GetSummary", ["steamid": "$steamid"]))
    }

    /// Spends points on one reward item. Steam refuses it when `expectedCost` no longer matches the price.
    public func redeemPoints(defid: UInt64, expectedCost: Int) async throws {
        _ = try await storeCall("LoyaltyRewards", "RedeemPoints", ["defid": String(defid), "expected_points_cost": expectedCost])
    }

    static func parsePoints(_ data: Data) -> PointsSummary {
        let summary = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["summary"] as? [String: Any] ?? [:]
        return PointsSummary(points: int(summary["points"]), earned: int(summary["points_earned"]), spent: int(summary["points_spent"]))
    }

    // MARK: - Workshop subscriptions

    /// Which of `ids` (items of `appid`) the account is subscribed to. Read-only.
    public func subscribedWorkshopItems(appid: UInt32, ids: [UInt64]) async throws -> Set<UInt64> {
        let body: [String: Any] = ["appid": appid, "publishedfileids": ids.map(String.init), "listtype": Self.subscribedListType]
        return Self.parseInList(try await storeCall("PublishedFile", "AreFilesInSubscriptionList", body))
    }

    public func setWorkshopSubscription(_ id: UInt64, appid: UInt32, subscribed: Bool) async throws {
        let body: [String: Any] = ["publishedfileid": String(id), "list_type": Self.subscribedListType, "appid": appid, "notify_client": true]
        _ = try await storeCall("PublishedFile", subscribed ? "Subscribe" : "Unsubscribe", body)
    }

    // EUCMListType: 1 subscribed, 2 favourites (read from steamui's enum).
    static let subscribedListType = 1

    static func parseInList(_ data: Data) -> Set<UInt64> {
        let files = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return Set(files.compactMap { f in f["inlist"] as? Bool == true ? UInt64(exactly: int(f["publishedfileid"])) : nil })
    }
}
