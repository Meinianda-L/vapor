import Foundation

/// Minimal PE/COFF reader: architecture, subsystem, imported DLLs (normal and
/// delay-load), whether it is a .NET assembly, plus a scan for DLL names that
/// appear only as strings (modules loaded at runtime via LoadLibrary).
public struct PEFile: Sendable {
    public enum Machine: String, Sendable { case i386, amd64, arm64, other }

    public let machine: Machine
    public let is64Bit: Bool
    public let isDotNet: Bool
    public let subsystem: UInt16
    /// Lower-cased DLL names from the import and delay-import tables.
    public let imports: Set<String>

    public init(url: URL) throws {
        // Memory-mapped: only the header and import pages are actually read.
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        guard data.count > 0x40, try r.u16() == 0x5A4D else { throw PEError.notPE("missing MZ") }
        r.pos = 0x3C
        let peOffset = Int(try r.u32())
        r.pos = peOffset
        guard try r.u32() == 0x0000_4550 else { throw PEError.notPE("missing PE signature") }
        let machineRaw = try r.u16()
        let sectionCount = Int(try r.u16())
        r.pos += 12
        let optionalSize = Int(try r.u16())
        r.pos += 2                                            // characteristics
        let optional = r.pos
        let magic = try r.u16()
        guard magic == 0x10B || magic == 0x20B else { throw PEError.notPE("bad optional header magic") }
        let is64 = magic == 0x20B

        r.pos = optional + 68
        let subsystem = try r.u16()
        r.pos = optional + (is64 ? 24 : 28)
        let imageBase: UInt64 = is64 ? try r.u64() : UInt64(try r.u32())
        r.pos = optional + (is64 ? 108 : 92)
        let dirCount = Int(try r.u32())
        func directory(_ i: Int) throws -> (rva: UInt32, size: UInt32) {
            guard i < dirCount else { return (0, 0) }
            var d = ByteReader(data, at: optional + (is64 ? 112 : 96) + i * 8)
            return (try d.u32(), try d.u32())
        }

        var sections: [(va: UInt32, vsize: UInt32, raw: UInt32, rawSize: UInt32)] = []
        var s = ByteReader(data, at: optional + optionalSize)
        for _ in 0..<sectionCount {
            s.pos += 8
            let vsize = try s.u32(), va = try s.u32(), rawSize = try s.u32(), raw = try s.u32()
            s.pos += 16
            sections.append((va, vsize, raw, rawSize))
        }
        // Section fields come straight from the file: widen before adding so garbage cannot overflow.
        func offset(_ rva: UInt32) -> Int? {
            for sec in sections where rva >= sec.va && UInt64(rva) < UInt64(sec.va) + UInt64(max(sec.vsize, sec.rawSize)) {
                let off = Int(rva - sec.va) + Int(sec.raw)
                return off < data.count ? off : nil
            }
            return nil
        }
        func name(at rva: UInt32) -> String? {
            guard let off = offset(rva) else { return nil }
            var n = ByteReader(data, at: off)
            return try? n.cString().lowercased()
        }

        var imports = Set<String>()
        let imp = try directory(1)
        if imp.rva != 0, var off = offset(imp.rva) {
            for _ in 0..<4096 {                                // 20-byte descriptors, zero-terminated
                var d = ByteReader(data, at: off)
                let thunk = try d.u32(); d.pos += 8
                let nameRVA = try d.u32(); let first = try d.u32()
                if thunk == 0 && nameRVA == 0 && first == 0 { break }
                if let n = name(at: nameRVA) { imports.insert(n) }
                off += 20
            }
        }
        let delay = try directory(13)
        if delay.rva != 0, var off = offset(delay.rva) {
            for _ in 0..<4096 {                                // 32-byte descriptors
                var d = ByteReader(data, at: off)
                let attributes = try d.u32()
                let nameField = try d.u32()
                if attributes == 0 && nameField == 0 { break }
                // Old-style descriptors store VAs instead of RVAs.
                let nameRVA = attributes & 1 == 1 ? nameField : UInt32(truncatingIfNeeded: UInt64(nameField) &- imageBase)
                if let n = name(at: nameRVA) { imports.insert(n) }
                off += 32
            }
        }
        let isDotNet = try directory(14).rva != 0
        self.machine = [0x14C: .i386, 0x8664: .amd64, 0xAA64: .arm64][machineRaw] ?? .other
        self.is64Bit = is64
        self.subsystem = subsystem
        self.imports = imports
        self.isDotNet = isDotNet
    }

    /// DLL names from `candidates` that appear anywhere in the file as ASCII or
    /// UTF-16LE text (case-insensitive). Catches LoadLibrary("d3d11.dll").
    /// Single pass over the file regardless of how many names are searched.
    public static func referencedNames(in url: URL, candidates: [String]) -> Set<String> {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        let names = candidates.map { Array($0.lowercased().utf8) }
        // 256-entry table indexed by the lower-cased first byte: O(1) reject per byte.
        var byFirst = [[Int]](repeating: [], count: 256)
        for (i, n) in names.enumerated() { byFirst[Int(n[0])].append(i) }
        var found = Set<Int>()
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let b = buf.bindMemory(to: UInt8.self)
            let count = b.count
            @inline(__always) func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c | 0x20 : c }
            var i = 0
            while i < count {
                let list = byFirst[Int(lower(b[i]))]
                if !list.isEmpty {
                    for idx in list where !found.contains(idx) {
                        let n = names[idx]
                        if i + n.count <= count {
                            var k = 1
                            while k < n.count && lower(b[i + k]) == n[k] { k += 1 }
                            if k == n.count { found.insert(idx); continue }
                        }
                        if i + n.count * 2 <= count {
                            var k = 0
                            while k < n.count && lower(b[i + 2 * k]) == n[k] && b[i + 2 * k + 1] == 0 { k += 1 }
                            if k == n.count { found.insert(idx) }
                        }
                    }
                    if found.count == names.count { return }
                }
                i += 1
            }
        }
        return Set(found.map { candidates[$0].lowercased() })
    }
}

public enum PEError: Error, Equatable { case notPE(String) }
