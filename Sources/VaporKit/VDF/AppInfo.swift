import Foundation

/// Reader for Steam's binary `appcache/appinfo.vdf` (formats v27, v28, v29).
///
/// v29 (magic 0x07564429) stores keys as indices into a string table whose
/// offset follows the header. Entries can be filtered by AppID so large caches
/// (100+ MB on big accounts) are not fully decoded.
public struct AppInfo: Sendable {
    public let version: UInt8
    public let apps: [UInt32: KeyValues]

    public init(contentsOf url: URL, only wanted: Set<UInt32>? = nil) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), only: wanted)
    }

    public init(data: Data, only wanted: Set<UInt32>? = nil) throws {
        var r = ByteReader(data)
        let magic = try r.u32()
        guard magic & 0xFFFF_FF00 == 0x0756_4400, (0x27...0x29).contains(magic & 0xFF) else {
            throw VDFError.badBinary(String(format: "unknown appinfo magic %08x", magic))
        }
        version = UInt8(magic & 0xFF)
        _ = try r.u32()                                  // universe

        var strings: [String]? = nil
        if version >= 0x29 {
            let tableOffset = Int(try r.i64())
            var t = ByteReader(data, at: tableOffset)
            let count = Int(try t.u32())
            var table: [String] = []
            table.reserveCapacity(count)
            for _ in 0..<count { table.append(try t.cString()) }
            strings = table
        }

        var apps: [UInt32: KeyValues] = [:]
        while true {
            let appid = try r.u32()
            if appid == 0 { break }
            let size = Int(try r.u32())
            let entryEnd = r.pos + size
            if let wanted, !wanted.contains(appid) { r.pos = entryEnd; continue }
            // infoState, lastUpdated, picsToken, sha1, changeNumber, [binary sha1 since v28]
            r.pos += 4 + 4 + 8 + 20 + 4 + (version >= 0x28 ? 20 : 0)
            var body = BinaryKV(reader: r, strings: strings)
            apps[appid] = try body.readObject()
            r.pos = entryEnd
        }
        self.apps = apps
    }

    public subscript(appid: UInt32) -> KeyValues? { apps[appid] }
}

/// Binary KeyValues as used inside appinfo/packageinfo.
struct BinaryKV {
    var reader: ByteReader
    let strings: [String]?

    mutating func key() throws -> String {
        if let strings {
            let i = Int(try reader.u32())
            guard i < strings.count else { throw VDFError.badBinary("string index \(i) out of range") }
            return strings[i]
        }
        return try reader.cString()
    }

    mutating func readObject() throws -> KeyValues {
        var children: [(key: String, value: KeyValues)] = []
        while true {
            let type = try reader.u8()
            if type == 0x08 || type == 0x0B { return .object(children) }
            let k = try key()
            let v: KeyValues
            switch type {
            case 0x00: v = try readObject()
            case 0x01: v = .string(try reader.cString())
            case 0x02, 0x04, 0x06: v = .int(Int64(try reader.i32()))
            case 0x03: v = .float(Double(try reader.f32()))
            case 0x07: v = .int(Int64(bitPattern: try reader.u64()))
            case 0x0A: v = .int(try reader.i64())
            default: throw VDFError.badBinary("unknown type \(type) at \(reader.pos)")
            }
            children.append((k, v))
        }
    }
}

/// Little-endian cursor over `Data`.
struct ByteReader {
    let data: Data
    var pos: Int

    init(_ data: Data, at pos: Int = 0) { self.data = data; self.pos = pos }

    private mutating func take<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard pos + n <= data.count else { throw VDFError.unexpectedEnd }
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: data.startIndex + pos ..< data.startIndex + pos + n)
        }
        pos += n
        return T(littleEndian: v)
    }

    mutating func u8() throws -> UInt8 { try take(UInt8.self) }
    mutating func u16() throws -> UInt16 { try take(UInt16.self) }
    mutating func u32() throws -> UInt32 { try take(UInt32.self) }
    mutating func u64() throws -> UInt64 { try take(UInt64.self) }
    mutating func i32() throws -> Int32 { try take(Int32.self) }
    mutating func i64() throws -> Int64 { try take(Int64.self) }
    mutating func f32() throws -> Float { Float(bitPattern: try take(UInt32.self)) }

    mutating func cString() throws -> String {
        let start = data.startIndex + pos
        guard let end = data[start...].firstIndex(of: 0) else { throw VDFError.unexpectedEnd }
        pos += end - start + 1
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}
