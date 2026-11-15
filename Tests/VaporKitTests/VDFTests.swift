import XCTest
@testable import VaporKit

final class VDFTests: XCTestCase {
    let sample = """
    "UserLocalConfigStore"
    {
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"apps"
    \t\t\t\t{
    \t\t\t\t\t"367450"
    \t\t\t\t\t{
    \t\t\t\t\t\t"LastPlayed"\t\t"1791796952"
    \t\t\t\t\t}
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    \t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
    }

    """

    func testRoundTripIsLossless() throws {
        let kv = try TextVDF.parse(sample)
        XCTAssertEqual(TextVDF.serialize(kv), sample)
        XCTAssertEqual(kv[path: "UserLocalConfigStore", "path"]?.string, "C:\\Program Files (x86)\\Steam")
    }

    func testCaseInsensitiveLookupAndSet() throws {
        var kv = try TextVDF.parse(sample)
        XCTAssertEqual(kv[path: "userlocalconfigstore", "software", "valve", "steam", "apps", "367450", "lastplayed"]?.int, 1_791_796_952)
        kv.set(.string("/opt/vapor-launch %command%"),
               at: ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "367450", "LaunchOptions"])
        kv.set(.string("x"), at: ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "620", "LaunchOptions"])
        let reparsed = try TextVDF.parse(TextVDF.serialize(kv))
        XCTAssertEqual(reparsed[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "367450", "LaunchOptions"]?.string,
                       "/opt/vapor-launch %command%")
        XCTAssertEqual(reparsed[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "367450", "LastPlayed"]?.string,
                       "1791796952", "existing keys survive an edit")
        XCTAssertEqual(reparsed[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "620", "LaunchOptions"]?.string, "x")
    }

    func testCommentsConditionalsAndBareTokens() throws {
        let kv = try TextVDF.parse("""
        // header comment
        "root" { key value [$WIN32] "quoted" "a\\"b" }
        """)
        XCTAssertEqual(kv[path: "root", "key"]?.string, "value")
        XCTAssertEqual(kv[path: "root", "quoted"]?.string, "a\"b")
    }

    func testUnterminatedInputThrows() {
        XCTAssertThrowsError(try TextVDF.parse("\"a\" { \"b\" \"c\""))
    }

    /// Builds a minimal v29 appinfo with one app and checks the string-table path.
    func testBinaryAppInfoV29() throws {
        var strings: [String] = []
        func idx(_ s: String) -> [UInt8] {
            if !strings.contains(s) { strings.append(s) }
            return le32(UInt32(strings.firstIndex(of: s)!))
        }
        var kv: [UInt8] = []
        kv += [0x00] + idx("appinfo")
        kv += [0x02] + idx("appid") + le32(620)
        kv += [0x00] + idx("common")
        kv += [0x01] + idx("name") + Array("Portal 2".utf8) + [0]
        kv += [0x01] + idx("oslist") + Array("windows,macos,linux".utf8) + [0]
        kv += [0x08]
        kv += [0x00] + idx("config")
        kv += [0x00] + idx("launch") + [0x00] + idx("0")
        kv += [0x01] + idx("executable") + Array("portal2.exe".utf8) + [0]
        kv += [0x00] + idx("config") + [0x01] + idx("oslist") + Array("windows".utf8) + [0, 0x08]
        kv += [0x08, 0x08, 0x08, 0x08, 0x08]

        let entryHeader = le32(0) + le32(0) + [UInt8](repeating: 0, count: 8 + 20) + le32(0) + [UInt8](repeating: 0, count: 20)
        var data: [UInt8] = le32(0x0756_4429) + le32(1) + [UInt8](repeating: 0, count: 8)
        data += le32(620) + le32(UInt32(entryHeader.count + kv.count)) + entryHeader + kv
        data += le32(0)
        let tableOffset = data.count
        data += le32(UInt32(strings.count))
        for s in strings { data += Array(s.utf8) + [0] }
        data.replaceSubrange(8..<16, with: withUnsafeBytes(of: Int64(tableOffset).littleEndian, Array.init))

        let info = try AppInfo(data: Data(data))
        XCTAssertEqual(info.version, 0x29)
        let meta = try XCTUnwrap(AppMetadata(appid: 620, info: try XCTUnwrap(info[620])))
        XCTAssertEqual(meta.name, "Portal 2")
        XCTAssertEqual(meta.osList, ["windows", "macos", "linux"])
        XCTAssertEqual(meta.windowsLaunch?.executable, "portal2.exe")
        XCTAssertFalse(meta.isWindowsOnly)

        let filtered = try AppInfo(data: Data(data), only: [999])
        XCTAssertNil(filtered[620], "filtered entries are skipped")
    }

    /// Real cache on this Mac, when present.
    func testRealAppInfoIfPresent() throws {
        let url = SteamInstall.nativeDefault.appInfoURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no native Steam appinfo")
        let info = try AppInfo(contentsOf: url)
        XCTAssertFalse(info.apps.isEmpty)
        let valve = ValveCompatManifest(appInfo: info)
        XCTAssertFalse(valve.configs.isEmpty, "Valve's SteamPlay manifest (891390) should be cached")
    }
}

func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
