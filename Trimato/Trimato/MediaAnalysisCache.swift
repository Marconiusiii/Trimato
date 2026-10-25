import CryptoKit
import Foundation

/// Reusable source analysis, independent of any editor window or saved selection.
actor MediaAnalysisCache {
    static let shared = MediaAnalysisCache()
    static let maximumByteCount: Int64 = 256 * 1_024 * 1_024
    private let root: URL?
    private let limit: Int64
    private let sharedTasks = SharedMediaTasks<String, Data>()
    private var flights: [String: UUID] = [:]
    private struct Envelope: Codable {
        let checksum: String
        let payload: Data
    }

    init(directory: URL? = nil, maximumByteCount: Int64 = MediaAnalysisCache.maximumByteCount) {
        root = directory
        limit = maximumByteCount
    }

    private func directory() throws -> URL {
        let url = try root ?? ProxyMediaManager.cacheDirectory().appendingPathComponent("Analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func key(source: URL, kind: String) throws -> String {
        let url = source.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = [url.path, kind, String(describing: attributes[.systemNumber]),
            String(describing: attributes[.systemFileNumber]), String(describing: attributes[.size]),
            String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)].joined(separator: "\n")
        return Self.digest(Data(identity.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func value(source: URL, kind: String, produce: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let cacheKey = try key(source: source, kind: kind)
        let path = try? directory().appendingPathComponent(cacheKey + ".json")
        if let path, let raw = try? Data(contentsOf: path), let cached = try? JSONDecoder().decode(Envelope.self, from: raw),
           Self.digest(cached.payload) == cached.checksum {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            return cached.payload
        }
        return try await sharedTasks.value(for: cacheKey) {
            try await self.produceValue(cacheKey: cacheKey, source: source, kind: kind, path: path, produce: produce)
        }
    }

    private func produceValue(cacheKey: String, source: URL, kind: String, path: URL?,
                              produce: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let id = UUID()
        flights[cacheKey] = id
        defer { if flights[cacheKey] == id { flights[cacheKey] = nil } }
        let data = try await produce()
        try Task.checkCancellation()
        guard try key(source: source, kind: kind) == cacheKey else { throw AnalysisError.sourceChanged }
        if let path, data.count <= limit,
           let encoded = try? JSONEncoder().encode(Envelope(checksum: Self.digest(data), payload: data)) {
            let free = try? path.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if root != nil || (free ?? 0) > MediaCacheManager.minimumAvailableByteCount + Int64(encoded.count) {
                try? encoded.write(to: path, options: .atomic)
                try? prune()
            }
        }
        return data
    }

    private func files() throws -> [(URL, Int64, Date)] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "json" }.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
    }

    private func prune() throws {
        let entries = try files().sorted { $0.2 < $1.2 }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for (url, bytes, _) in entries where total > limit {
            try FileManager.default.removeItem(at: url)
            total -= bytes
        }
    }

    func status() throws -> (bytes: Int64, count: Int) {
        let entries = try files()
        return (entries.reduce(0) { $0 + $1.1 }, entries.count)
    }

    func clear(_ scope: MediaCacheClearScope) throws -> MediaCacheClearResult {
        var result = MediaCacheClearResult(removedByteCount: 0, removedFileCount: 0, retainedActiveFileCount: flights.count)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for (url, bytes, lastUsed) in try files() {
            guard flights[url.deletingPathExtension().lastPathComponent] == nil,
                  scope == .all || lastUsed < cutoff else { continue }
            try FileManager.default.removeItem(at: url)
            result.removedByteCount += bytes
            result.removedFileCount += 1
        }
        return result
    }
}

nonisolated enum AnalysisError: LocalizedError {
    case sourceChanged, emptyFrameIndex
    var errorDescription: String? {
        switch self {
        case .sourceChanged: "The source changed while Trimato was preparing it. Open the clip again to retry."
        case .emptyFrameIndex: "Trimato could not build the video frame index. Retry opening this clip."
        }
    }
}
