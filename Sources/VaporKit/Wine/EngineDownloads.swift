import CryptoKit
import Foundation

/// A downloadable engine or renderer pack, from a GitHub release.
public struct RemoteAsset: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case engine
        case pack(PackKind)
    }

    public let kind: Kind
    public let repository: String
    /// Release asset file name, e.g. `WS12WineSikarugir10.0_8.tar.xz`.
    public let name: String
    public let release: String
    public let size: Int64
    public let url: URL
    /// GitHub's `sha256:` digest, when the release records one.
    public let sha256: String?
    public let published: Date?
    public let prerelease: Bool

    public var id: String { url.absoluteString }

    /// Folder it installs to: Engines/<installName> or Packs/<kind>/<installName>.
    public var installName: String {
        switch kind {
        case .engine: return Self.safeName(Self.stripArchiveExtension(name))
        case .pack: return Self.safeName(release)
        }
    }

    static func stripArchiveExtension(_ name: String) -> String {
        for ext in [".tar.xz", ".tar.gz", ".tar.bz2", ".tgz", ".txz", ".tar"] where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    static func safeName(_ s: String) -> String {
        let cleaned = String(s.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }
}

/// Progress of one download-and-install. Byte counts are nil-free; `total` is 0 when unknown.
public enum DownloadEvent: Sendable, Equatable {
    case downloading(received: Int64, total: Int64)
    case verifying
    case extracting
    case validating
    case finished(URL)
}

/// What an archive turned into once installed.
public enum InstalledItem: Sendable, Hashable {
    case engine(WineEngine)
    case pack(RendererPack)

    public var root: URL {
        switch self {
        case let .engine(e): return e.root
        case let .pack(p): return p.root
        }
    }
}

/// Lists, downloads and installs engines and renderer packs from GitHub releases.
/// Cancelling the calling task cancels the transfer or extraction and throws `CancellationError`.
public struct EngineDownloads: Sendable {
    public struct Source: Sendable {
        public let repository: String
        /// nil: engines.
        public let pack: PackKind?
    }

    public static let sources: [Source] = [
        Source(repository: "3Shain/dxmt", pack: .dxmt),
        Source(repository: "Gcenx/DXVK-macOS", pack: .dxvk),
        Source(repository: "Sikarugir-App/Engines", pack: nil),
        Source(repository: "Gcenx/macOS_Wine_builds", pack: nil),
    ]

    public let locations: VaporLocations
    private let session: URLSession

    public init(locations: VaporLocations = .standard, session: URLSession? = nil) {
        self.locations = locations
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Listing

    /// Every option from all sources; a source that fails is skipped unless all fail.
    public func remoteOptions() async throws -> [RemoteAsset] {
        let results = await withTaskGroup(of: (Int, Result<[RemoteAsset], Error>).self) { group in
            for (i, source) in Self.sources.enumerated() {
                group.addTask {
                    do { return (i, .success(try await releases(of: source.repository))) } catch { return (i, .failure(error)) }
                }
            }
            var out: [(Int, Result<[RemoteAsset], Error>)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let assets = results.flatMap { (try? $0.get()) ?? [] }
        if assets.isEmpty, let failure = results.lazy.compactMap({ r -> Error? in if case let .failure(e) = r { return e }; return nil }).first {
            throw failure
        }
        return assets
    }

    public func releases(of repository: String) async throws -> [RemoteAsset] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10") else { throw WineSetupError.badReleaseData }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Vapor", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw Self.mapTransport(error) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if [403, 429].contains(http.statusCode), http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" { throw WineSetupError.rateLimited }
            throw WineSetupError.httpStatus(http.statusCode)
        }
        return try Self.parseReleases(data, repository: repository)
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let published_at: Date?
        let assets: [APIAsset]
    }

    private struct APIAsset: Decodable {
        let name: String
        let size: Int64
        let browser_download_url: URL
        let digest: String?
        let updated_at: Date?
    }

    /// Picks the assets Vapor can use out of a `/releases` response, newest first.
    public static func parseReleases(_ data: Data, repository: String) throws -> [RemoteAsset] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let releases = try? decoder.decode([APIRelease].self, from: data) else { throw WineSetupError.badReleaseData }
        let pack = sources.first { $0.repository == repository }?.pack
        var out: [RemoteAsset] = []
        for release in releases where release.draft != true {
            var picked = release.assets.filter { accepts($0.name, repository: repository) }
            // DXVK-macOS ships each build twice; the -builtin one carries Wine's builtin marker so it
            // loads from lib/wine without DLL overrides.
            if repository == "Gcenx/DXVK-macOS", picked.contains(where: { $0.name.contains("-builtin") }) {
                picked = picked.filter { $0.name.contains("-builtin") }
            }
            for a in picked {
                let digest = a.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
                out.append(RemoteAsset(kind: pack.map(RemoteAsset.Kind.pack) ?? .engine, repository: repository, name: a.name,
                                       release: release.tag_name, size: a.size, url: a.browser_download_url, sha256: digest,
                                       published: a.updated_at ?? release.published_at, prerelease: release.prerelease ?? false))
            }
        }
        // Sikarugir keeps every engine in one release, so order by the asset's own date.
        return out.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
    }

    static func accepts(_ name: String, repository: String) -> Bool {
        let lower = name.lowercased()
        switch repository {
        case "3Shain/dxmt":
            return lower.hasPrefix("dxmt-") && lower.hasSuffix("-builtin.tar.gz")
        case "Gcenx/DXVK-macOS":
            return lower.hasPrefix("dxvk-macos") && lower.hasSuffix(".tar.gz") && !lower.contains("crossover")
        case "Sikarugir-App/Engines":
            // Windows Steam is 64-bit only, so the 32-bit-only engines are left out.
            return name.hasPrefix("WS") && name.contains("Wine") && lower.hasSuffix(".tar.xz") && !name.contains("32Bit")
        case "Gcenx/macOS_Wine_builds":
            return lower.hasPrefix("wine-") && lower.hasSuffix("-osx64.tar.xz")
        default:
            return false
        }
    }

    // MARK: - Download and install

    /// Downloads `asset`, checks its digest, extracts and validates it. An asset already installed
    /// is returned without downloading again.
    public func download(_ asset: RemoteAsset, progress: @escaping @Sendable (DownloadEvent) -> Void = { _ in }) async throws -> InstalledItem {
        if let existing = installed(asset) {
            progress(.finished(existing.root))
            return existing
        }
        let fm = FileManager.default
        try fm.createDirectory(at: locations.downloads, withIntermediateDirectories: true)
        try checkSpace(for: asset)
        let archive = locations.downloads.appendingPathComponent(RemoteAsset.safeName(asset.name))
        defer { try? FileOps.remove(archive) }
        try await fetch(asset.url, to: archive) { progress(.downloading(received: $0, total: $1 > 0 ? $1 : asset.size)) }
        if let expected = asset.sha256 {
            progress(.verifying)
            let actual = try await offloaded { try Self.sha256(of: archive) }
            guard actual == expected else { throw WineSetupError.checksumMismatch(asset.name) }
        }
        return try await install(archive: archive, kind: asset.kind, name: asset.installName, progress: progress)
    }

    /// Already-installed copy of `asset`, if valid.
    public func installed(_ asset: RemoteAsset) -> InstalledItem? {
        switch asset.kind {
        case .engine:
            let dir = locations.engines.appendingPathComponent(asset.installName)
            return EngineCatalog.locateRoot(in: dir).flatMap { WineEngine(root: $0, source: .vapor, name: asset.installName) }.map(InstalledItem.engine)
        case let .pack(kind):
            let dir = locations.packs(kind).appendingPathComponent(asset.installName)
            return RendererPack(kind: kind, root: dir, origin: .vapor).map(InstalledItem.pack)
        }
    }

    /// Installs a local archive (.tar.xz / .tar.gz). `kind` nil detects engine or pack from the content;
    /// `name` defaults to the archive name (engines) or the pack's own version (packs). An existing
    /// install of the same name is replaced.
    public func install(archive: URL, kind: RemoteAsset.Kind? = nil, name: String? = nil,
                        progress: @escaping @Sendable (DownloadEvent) -> Void = { _ in }) async throws -> InstalledItem {
        let fm = FileManager.default
        try fm.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let staging = locations.root.appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileOps.remove(staging) }

        progress(.extracting)
        let tar = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
        guard tar.status == 0 else {
            throw WineSetupError.extractFailed(tar.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(localized: "tar 退出码 \(tar.status)"))
        }

        progress(.validating)
        let content = Self.contentRoot(of: staging)
        let label = name ?? RemoteAsset.stripArchiveExtension(archive.lastPathComponent)
        let resolvedKind: RemoteAsset.Kind
        if let kind {
            resolvedKind = kind
        } else if EngineCatalog.locateRoot(in: content) != nil {
            resolvedKind = .engine
        } else if let packKind = RendererPack.detectKind(at: content) {
            resolvedKind = .pack(packKind)
        } else {
            throw WineSetupError.invalidEngine(label)
        }

        switch resolvedKind {
        case .engine:
            guard EngineCatalog.locateRoot(in: content) != nil else { throw WineSetupError.invalidEngine(label) }
            let folder = RemoteAsset.safeName(label)
            let dest = locations.engines.appendingPathComponent(folder, isDirectory: true)
            try replace(dest, with: content)
            guard let root = EngineCatalog.locateRoot(in: dest), let engine = WineEngine(root: root, source: .vapor, name: folder) else {
                throw WineSetupError.invalidEngine(label)
            }
            progress(.finished(engine.root))
            return .engine(engine)
        case let .pack(packKind):
            guard let probe = RendererPack(kind: packKind, root: content, origin: .vapor) else { throw WineSetupError.invalidPack(packKind, label) }
            let folder = RemoteAsset.safeName(name ?? probe.version)
            let dest = locations.packs(packKind).appendingPathComponent(folder, isDirectory: true)
            try replace(dest, with: content)
            guard let pack = RendererPack(kind: packKind, root: dest, origin: .vapor, version: name ?? probe.version) else {
                throw WineSetupError.invalidPack(packKind, label)
            }
            progress(.finished(pack.root))
            return .pack(pack)
        }
    }

    /// Archives usually wrap everything in one folder (`v0.80/`, `wswine.bundle/`, `Wine Devel.app/`);
    /// that folder becomes the install.
    static func contentRoot(of staging: URL) -> URL {
        let items = FileOps.children(staging)
        if items.count == 1, let only = items.first, FileOps.isDirectory(only), !only.lastPathComponent.hasSuffix(".app") { return only }
        return staging
    }

    private func replace(_ dest: URL, with content: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileOps.remove(dest)
        try fm.moveItem(at: content, to: dest)
    }

    private func checkSpace(for asset: RemoteAsset) throws {
        // xz engines unpack to about 4.5x their size; keep room for the archive as well.
        let factor: Int64 = asset.name.lowercased().hasSuffix(".xz") ? 6 : 4
        let needed = asset.size * factor
        let values = try? locations.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed { throw WineSetupError.notEnoughSpace(needed: needed) }
    }

    /// Downloads `url` to `destination` with a URLSession download task, reporting (received, expected).
    public func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        try Task.checkCancellation()
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        let transfer = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { transfer.finishTasksAndInvalidate() }
        let task = transfer.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.continuation = c
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func mapTransport(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return CancellationError() }
        if let e = error as? WineSetupError { return e }
        return WineSetupError.network(ns.localizedDescription)
    }
}

/// Bridges one URLSession download task to async/await. The file is moved inside
/// didFinishDownloadingTo because URLSession deletes it when that callback returns.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var lastReport = Date.distantPast
    private var _continuation: CheckedContinuation<Void, Error>?

    var continuation: CheckedContinuation<Void, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return _continuation }
        set { lock.lock(); _continuation = newValue; lock.unlock() }
    }

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastReport) >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite
        if due { lastReport = now }
        lock.unlock()
        if due { progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Result<Void, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(WineSetupError.httpStatus(http.statusCode))
        } else {
            result = Result {
                try FileOps.remove(destination)
                try FileManager.default.moveItem(at: location, to: destination)
            }
        }
        lock.lock(); outcome = result; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = _continuation
        _continuation = nil
        let done = outcome
        lock.unlock()
        if let error {
            c?.resume(throwing: EngineDownloads.mapTransport(error))
        } else {
            c?.resume(with: done ?? .failure(WineSetupError.network(String(localized: "下载没有返回文件。"))))
        }
    }
}
