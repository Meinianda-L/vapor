import Foundation

/// Runs a tool to completion without blocking the caller's thread, with a timeout and
/// task cancellation (both terminate the process).
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    enum Output: Sendable {
        case capture
        /// Wine children (wineserver, services) inherit stdout and outlive the command, so a pipe
        /// would never reach EOF; their output goes to a log file instead.
        case append(URL)
        case discard
    }

    static func run(_ tool: URL, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval? = nil, output: Output = .capture) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        // Captured output goes through a temporary file rather than a pipe for the same reason.
        var captureURL: URL?
        let sink: FileHandle?
        switch output {
        case .capture:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vapor-\(UUID().uuidString).out")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            captureURL = url
            sink = try FileHandle(forWritingTo: url)
        case let .append(url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            sink = try FileHandle(forWritingTo: url)
            sink?.seekToEndOfFile()
        case .discard:
            sink = nil
        }
        process.standardOutput = sink ?? FileHandle.nullDevice
        process.standardError = sink ?? FileHandle.nullDevice
        defer {
            try? sink?.close()
            if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
        }

        let timedOut = Flag()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    c.resume(throwing: error)
                    return
                }
                // A cancel that landed before launch found nothing to stop.
                if Task.isCancelled { Self.stop(process) }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        timedOut.set()
                        Self.stop(process)
                    }
                }
            }
        } onCancel: {
            Self.stop(process)
        }
        try Task.checkCancellation()
        let text = captureURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return Result(status: status, output: text, timedOut: timedOut.isSet)
    }

    /// SIGTERM, then SIGKILL if the process ignores it.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// Blocking file work (clones, copies, hashing) moved off the cooperative thread pool.
func offloaded<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async {
            c.resume(with: Swift.Result { try body() })
        }
    }
}

enum FileOps {
    /// APFS clone (copy-on-write, what `cp -c` does; a directory is cloned whole), or a plain copy
    /// where the volume cannot clone. Returns whether it cloned. Symlinks are copied as symlinks.
    @discardableResult
    static func cloneOrCopy(_ source: URL, to destination: URL) throws -> Bool {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return true }
        let err = errno
        // ENOTSUP: not APFS; EXDEV: another volume. Anything else is a real failure.
        guard err == ENOTSUP || err == EXDEV else {
            throw WineSetupError.copyFailed("\(destination.lastPathComponent): \(String(cString: strerror(err)))")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return false
    }

    /// Removes a file, directory or (dangling) symlink; absent is fine.
    static func remove(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func children(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Resolved, standardised path: the identity used to de-duplicate engines and packs.
    static func canonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
}
