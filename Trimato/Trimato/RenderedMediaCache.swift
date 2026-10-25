import CryptoKit
import Foundation

/// Completed renders are immutable. Each caller receives its own removable hard link.
actor RenderedMediaCache {
    static let shared = RenderedMediaCache()
    static let maximumByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let sharedTasks = SharedMediaTasks<String, URL>()
    private var users: [String: Int] = [:]
    private var transient: [String: URL] = [:]
    private let root: URL?
    private let limit: Int64

    init(directory: URL? = nil, maximumByteCount: Int64 = RenderedMediaCache.maximumByteCount) {
        root = directory
        limit = maximumByteCount
    }

    nonisolated static func key(source: URL, recipe: Data) throws -> String {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let identity = ["render-v1", source.path, String(describing: attributes[.systemNumber]),
            String(describing: attributes[.systemFileNumber]), String(describing: attributes[.size]),
            String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8) + recipe).map { String(format: "%02x", $0) }.joined()
    }

    private func directory() throws -> URL {
        let url = try root ?? ProxyMediaManager.cacheDirectory().appendingPathComponent("Rendered", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func value(source: URL, recipe: Data, produce: @escaping @Sendable () async throws -> URL) async throws -> URL {
        try Task.checkCancellation()
        let key = try Self.key(source: source, recipe: recipe)
        // A cache is optional; an unavailable cache must not prevent editing or export.
        guard let directory = try? directory() else { return try await produce() }
        users[key, default: 0] += 1
        defer {
            users[key, default: 1] -= 1
            if users[key] == 0 {
                users[key] = nil
                if let file = transient.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }
            }
            try? prune()
        }
        let path = directory.appendingPathComponent(key).appendingPathExtension("mov")
        let cached: URL
        if FileManager.default.fileExists(atPath: path.path) { cached = path }
        else {
            cached = try await sharedTasks.value(for: key) {
                let output = try await produce()
                do {
                    try Task.checkCancellation()
                    guard try Self.key(source: source, recipe: recipe) == key else { throw AnalysisError.sourceChanged }
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    throw error
                }
                return try await self.store(output, key: key, at: path)
            }
        }
        try Task.checkCancellation()
        let leases = try TemporaryMediaSession.directory(named: "TrimatoRenderLeases")
        let lease = leases.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            do { try FileManager.default.linkItem(at: cached, to: lease) }
            catch { try FileManager.default.copyItem(at: cached, to: lease) }
        } catch {
            try? FileManager.default.removeItem(at: lease)
            throw error
        }
        let usage = path.deletingPathExtension().appendingPathExtension("used")
        if FileManager.default.fileExists(atPath: usage.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: usage.path)
        } else { try? Data().write(to: usage, options: .atomic) }
        return lease
    }

    private func store(_ output: URL, key: String, at path: URL) throws -> URL {
        guard !Task.isCancelled, users[key, default: 0] > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        let staging = path.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            do { try FileManager.default.linkItem(at: output, to: staging) }
            catch { try FileManager.default.copyItem(at: output, to: staging) }
            try FileManager.default.moveItem(at: staging, to: path)
            try? FileManager.default.removeItem(at: output)
            return path
        } catch {
            // Share a completed temporary render even if Caches became unwritable.
            transient[key] = output
            return output
        }
    }

    private func files() throws -> [(url: URL, bytes: Int64, used: Date)] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "mov" }.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let usage = url.deletingPathExtension().appendingPathExtension("used")
                let used = try? usage.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (url, Int64(values.fileSize ?? 0), used ?? values.contentModificationDate ?? .distantPast)
            }
    }

    private func prune() throws {
        let entries = try files().sorted { $0.used < $1.used }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        let free = try? directory().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        var available = free ?? Int64.max
        for entry in entries where total > limit || (root == nil && available < MediaCacheManager.minimumAvailableByteCount) {
            guard users[entry.url.deletingPathExtension().lastPathComponent] == nil else { continue }
            try FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: entry.url.deletingPathExtension().appendingPathExtension("used"))
            total -= entry.bytes
            available = (try? directory().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? available
        }
    }

    func status() throws -> (bytes: Int64, count: Int) {
        let entries = try files()
        return (entries.reduce(0) { $0 + $1.bytes }, entries.count)
    }

    func clear(_ scope: MediaCacheClearScope) throws -> MediaCacheClearResult {
        var result = MediaCacheClearResult(removedByteCount: 0, removedFileCount: 0, retainedActiveFileCount: users.count)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for entry in try files() {
            guard users[entry.url.deletingPathExtension().lastPathComponent] == nil,
                  scope == .all || entry.used < cutoff else { continue }
            try FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: entry.url.deletingPathExtension().appendingPathExtension("used"))
            result.removedByteCount += entry.bytes
            result.removedFileCount += 1
        }
        return result
    }
}
