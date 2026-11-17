import Foundation

/// A Steam install script (installscript.vdf): the registry values and first-run programs (redistributables)
/// Steam applies before a game's first launch, in LaunchApp's RunningInstallScript step.
public struct InstallScript: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case dword(UInt32)
    }

    public struct RegistryValue: Sendable, Equatable {
        /// Full key path as the script spells it, e.g. `HKEY_LOCAL_MACHINE\Software\Valve\cs2`.
        public let key: String
        public let name: String
        public let value: Value
    }

    public struct Step: Sendable, Equatable {
        /// Windows path, with %INSTALLDIR% expanded.
        public let program: String
        public let arguments: String
    }

    /// One "Run Process" entry; Steam marks it done by setting the value named `name` under `hasRunKey`.
    public struct Run: Sendable, Equatable {
        public let name: String
        public let hasRunKey: String?
        public let steps: [Step]
        public let requires64Bit: Bool

        /// The registry value that records this entry as done, as Steam writes it.
        public var doneMarker: RegistryValue? { hasRunKey.map { RegistryValue(key: $0, name: name, value: .dword(1)) } }
    }

    public let registry: [RegistryValue]
    public let runs: [Run]

    public var isEmpty: Bool { registry.isEmpty && runs.isEmpty }

    /// `installDir` is the Windows path that replaces %INSTALLDIR%.
    public init(_ kv: KeyValues, installDir: String) {
        let root = kv["installscript"] ?? kv
        func expand(_ s: String) -> String {
            s.replacingOccurrences(of: "%INSTALLDIR%", with: installDir, options: .caseInsensitive)
        }
        var registry: [RegistryValue] = []
        for (key, types) in root["registry"]?.children ?? [] {
            for (type, values) in types.children {
                for (name, v) in values.children {
                    guard let raw = v.string else { continue }
                    switch type.lowercased() {
                    case "string": registry.append(RegistryValue(key: key, name: name, value: .string(expand(raw))))
                    case "dword": registry.append(RegistryValue(key: key, name: name, value: .dword(UInt32(truncatingIfNeeded: v.int ?? 0))))
                    default: continue
                    }
                }
            }
        }
        var runs: [Run] = []
        for (name, entry) in root["run process"]?.children ?? [] {
            var steps: [Step] = []
            for i in 1...32 {
                guard let program = entry["process \(i)"]?.string else { break }
                steps.append(Step(program: expand(program), arguments: expand(entry["command \(i)"]?.string ?? "")))
            }
            guard !steps.isEmpty else { continue }
            runs.append(Run(name: name, hasRunKey: entry["hasrunkey"]?.string, steps: steps,
                            requires64Bit: entry[path: "requirement_os", "is64bitwindows"]?.int == 1))
        }
        self.registry = registry
        self.runs = runs
    }

    public static func load(_ url: URL, installDir: String) -> InstallScript? {
        guard let kv = try? TextVDF.parse(contentsOf: url) else { return nil }
        let script = InstallScript(kv, installDir: installDir)
        return script.isEmpty ? nil : script
    }

    /// Entries not yet recorded as done in `registry`; an entry without a HasRunKey runs every time, as in Steam.
    public func pendingRuns(in registry: RegistrySnapshot) -> [Run] {
        runs.filter { run in run.doneMarker.map { !registry.isSet($0.key, $0.name) } ?? true }
    }
}

/// Read-only view of a Wine prefix's registry files (system.reg, user.reg), enough to tell whether a value is set.
/// wineserver writes them out lazily, so a value set seconds ago may be missing; callers only use this to skip work.
public struct RegistrySnapshot: Sendable {
    /// Lower-cased full key (HKEY_LOCAL_MACHINE\…) → lower-cased value name → raw value text.
    private var keys: [String: [String: String]] = [:]

    public init() {}

    public init(prefix: URL) {
        for (file, hive) in [("system.reg", "HKEY_LOCAL_MACHINE"), ("user.reg", "HKEY_CURRENT_USER")] {
            if let text = try? String(contentsOf: prefix.appendingPathComponent(file), encoding: .utf8) { add(text, hive: hive) }
        }
    }

    /// Adds one Wine .reg file whose keys are relative to `hive`.
    public mutating func add(_ text: String, hive: String) {
        var current: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                guard let close = line.lastIndex(of: "]") else { current = nil; continue }
                let path = line[line.index(after: line.startIndex)..<close].replacingOccurrences(of: "\\\\", with: "\\")
                current = (hive + "\\" + path).lowercased()
                if let current, keys[current] == nil { keys[current] = [:] }
            } else if let key = current, line.hasPrefix("\""), let eq = Self.nameEnd(line) {
                let name = line[line.index(after: line.startIndex)..<eq].replacingOccurrences(of: "\\\\", with: "\\")
                keys[key]?[name.lowercased()] = String(line[line.index(eq, offsetBy: 2)...])
            }
        }
    }

    /// Index of the quote closing a value name (`"name"=…`), skipping escaped quotes.
    private static func nameEnd(_ line: Substring) -> Substring.Index? {
        var i = line.index(after: line.startIndex), escaped = false
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                let next = line.index(after: i)
                return next < line.endIndex && line[next] == "=" ? i : nil
            }
            i = line.index(after: i)
        }
        return nil
    }

    /// The value exists and is not zero, in either registry view (Steam writes HKLM\Software through the 32-bit one).
    public func isSet(_ key: String, _ name: String) -> Bool {
        RegFile.views(of: RegFile.canonical(key)).contains { k in
            guard let raw = keys[k.lowercased()]?[name.lowercased()] else { return false }
            return raw != "dword:00000000" && raw != "\"\"" && raw != "\"0\""
        }
    }
}

/// Builds .reg files for `regedit /S`.
public enum RegFile {
    public enum Entry: Sendable, Equatable {
        case value(InstallScript.RegistryValue)
        case deleteValue(key: String, name: String)
    }

    /// The key with its hive spelled out (HKLM → HKEY_LOCAL_MACHINE) and single backslashes.
    static func canonical(_ key: String) -> String {
        var parts = key.replacingOccurrences(of: "/", with: "\\").split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard let hive = parts.first else { return key }
        let full = ["hklm": "HKEY_LOCAL_MACHINE", "hkcu": "HKEY_CURRENT_USER", "hkcr": "HKEY_CLASSES_ROOT", "hku": "HKEY_USERS"]
        parts[0] = full[hive.lowercased()] ?? hive.uppercased()
        return parts.joined(separator: "\\")
    }

    /// HKLM\Software keys in the 32-bit view (where Steam writes them) first, then the native one.
    static func views(of key: String) -> [String] {
        let parts = key.split(separator: "\\").map(String.init)
        guard parts.count > 2, parts[0] == "HKEY_LOCAL_MACHINE", parts[1].lowercased() == "software" else { return [key] }
        if parts[2].lowercased() == "wow6432node" { return [key] }
        return [([parts[0], parts[1], "Wow6432Node"] + parts[2...]).joined(separator: "\\"), key]
    }

    /// Where Vapor writes a value so that Steam reads it the way it reads its own.
    static func target(_ key: String) -> String { views(of: canonical(key))[0] }

    /// A Unicode .reg file (regedit reads UTF-16 with a BOM, so non-ASCII install paths survive).
    public static func text(_ entries: [Entry]) -> String {
        var out = "Windows Registry Editor Version 5.00\r\n"
        var current: String?
        for entry in entries {
            switch entry {
            case let .deleteValue(key, name):
                let key = target(key)
                if key != current { out += "\r\n[\(key)]\r\n"; current = key }
                out += "\"\(escape(name))\"=-\r\n"
            case let .value(v):
                let key = target(v.key)
                if key != current { out += "\r\n[\(key)]\r\n"; current = key }
                let name = "\"\(escape(v.name))\""
                switch v.value {
                case let .string(s): out += "\(name)=\"\(escape(s))\"\r\n"
                case let .dword(d): out += "\(name)=dword:\(String(format: "%08x", d))\r\n"
                }
            }
        }
        return out
    }

    public static func data(_ entries: [Entry]) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(text(entries).data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
