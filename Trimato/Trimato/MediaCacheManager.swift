import Foundation

nonisolated enum MediaCacheClearScope: Equatable, Sendable {
    case unused
    case all
}

nonisolated struct MediaCacheStatus: Sendable {
    var byteCount: Int64
    var fileCount: Int
    var location: URL
}

nonisolated struct MediaCacheClearResult: Sendable {
    var removedByteCount: Int64
    var removedFileCount: Int
    var retainedActiveFileCount: Int
}

nonisolated enum MediaCacheError: LocalizedError {
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            "There is not enough available disk space to create a playback proxy while keeping 10 GB free."
        }
    }
}

nonisolated struct MediaCacheEvictionCandidate: Sendable {
    var cacheKey: UUID
    var byteCount: Int64
    var lastUsed: Date
}

nonisolated enum MediaCacheEvictionPolicy {
    static func keysToRemove(
        candidates: [MediaCacheEvictionCandidate],
        protectedKeys: Set<UUID>,
        totalByteCount: Int64,
        availableByteCount: Int64,
        maximumByteCount: Int64,
        minimumAvailableByteCount: Int64
    ) -> [UUID] {
        var total = totalByteCount
        var available = availableByteCount
        var result: [UUID] = []
        for candidate in candidates.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > maximumByteCount || available < minimumAvailableByteCount else { break }
            guard !protectedKeys.contains(candidate.cacheKey) else { continue }
            result.append(candidate.cacheKey)
            total -= candidate.byteCount
            available += candidate.byteCount
        }
        return result
    }
}

actor MediaCacheManager {
    static let shared = MediaCacheManager()
    static let maximumByteCount: Int64 = 10 * 1_024 * 1_024 * 1_024
    static let minimumAvailableByteCount: Int64 = 10 * 1_024 * 1_024 * 1_024

    private struct Entry: Codable, Sendable {
        var cacheKey: UUID
        var fingerprint: SourceMediaFingerprint
        var byteCount: Int64
        var lastUsed: Date
    }

    private struct Index: Codable, Sendable {
        var entries: [UUID: Entry] = [:]
    }

    private var index = Index()
    private var hasLoadedIndex = false
    private var inFlight: [UUID: Task<URL, Error>] = [:]
    private var protectedKeysByOwner: [UUID: Set<UUID>] = [:]
    private var pendingRemoval: Set<UUID> = []

    nonisolated static func sourceFingerprint(for url: URL) throws -> SourceMediaFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return SourceMediaFingerprint(
            fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            proxyFormatVersion: SourceMediaFingerprint.proxyFormatVersion
        )
    }

    func ensureProxy(
        sourceURL: URL,
        duration: Double,
        cacheKey: UUID,
        fingerprint: SourceMediaFingerprint,
        hasVideo: Bool = true,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try loadIndexIfNeeded()
        if let task = inFlight[cacheKey] {
            return try await task.value
        }

        if var entry = index.entries[cacheKey],
           entry.fingerprint == fingerprint,
           let url = validProxyURL(for: cacheKey) {
            entry.lastUsed = Date()
            entry.byteCount = fileByteCount(at: url)
            index.entries[cacheKey] = entry
            try saveIndex()
            return url
        }

        let task = Task<URL, Error> {
            try await ProxyMediaManager.createCachedProxy(
                sourceURL: sourceURL,
                duration: duration,
                cacheKey: cacheKey,
                hasVideo: hasVideo,
                progress: progress
            )
        }
        inFlight[cacheKey] = task
        do {
            let url = try await task.value
            inFlight[cacheKey] = nil
            index.entries[cacheKey] = Entry(
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                byteCount: fileByteCount(at: url),
                lastUsed: Date()
            )
            try saveIndex()
            _ = try await enforceLimits(additionalProtectedKeys: [cacheKey])
            return url
        } catch {
            inFlight[cacheKey] = nil
            throw error
        }
    }

    func existingProxy(
        cacheKey: UUID,
        fingerprint: SourceMediaFingerprint
    ) throws -> URL? {
        try loadIndexIfNeeded()
        guard var entry = index.entries[cacheKey],
              entry.fingerprint == fingerprint,
              let url = validProxyURL(for: cacheKey) else { return nil }
        entry.lastUsed = Date()
        entry.byteCount = fileByteCount(at: url)
        index.entries[cacheKey] = entry
        try saveIndex()
        return url
    }

    func adoptProxy(
        at sourceURL: URL,
        cacheKey: UUID,
        fingerprint: SourceMediaFingerprint
    ) async throws -> URL {
        try loadIndexIfNeeded()
        if let existing = validProxyURL(for: cacheKey) {
            return existing
        }

        let destination = try ProxyMediaManager.cachedProxyURL(for: cacheKey)
        let temporary = try ProxyMediaManager.cacheDirectory()
            .appendingPathComponent("\(cacheKey.uuidString).partial.\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            index.entries[cacheKey] = Entry(
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                byteCount: fileByteCount(at: destination),
                lastUsed: Date()
            )
            try saveIndex()
            _ = try await enforceLimits(additionalProtectedKeys: [cacheKey])
            return destination
        } catch {
            ProxyMediaManager.removeProxy(at: temporary)
            if index.entries[cacheKey] != nil && validProxyURL(for: cacheKey) == nil {
                index.entries[cacheKey] = nil
                try? saveIndex()
            }
            throw error
        }
    }

    func updateProtectedKeys(owner: UUID, keys: Set<UUID>) async {
        protectedKeysByOwner[owner] = keys
        try? removePendingProxies()
    }

    func releaseProtectedKeys(owner: UUID) async {
        protectedKeysByOwner[owner] = nil
        try? removePendingProxies()
        _ = try? await enforceLimits()
    }

    func status() throws -> MediaCacheStatus {
        try loadIndexIfNeeded()
        reconcileIndex()
        try saveIndex()
        return MediaCacheStatus(
            byteCount: index.entries.values.reduce(0) { $0 + $1.byteCount },
            fileCount: index.entries.count,
            location: try ProxyMediaManager.cacheDirectory()
        )
    }

    func clear(_ scope: MediaCacheClearScope) throws -> MediaCacheClearResult {
        try loadIndexIfNeeded()
        reconcileIndex()
        let protectedKeys = allProtectedKeys
        let unusedCutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var removedBytes: Int64 = 0
        var removedFiles = 0
        var retainedActiveFiles = 0

        for entry in Array(index.entries.values) {
            if protectedKeys.contains(entry.cacheKey) || inFlight[entry.cacheKey] != nil {
                retainedActiveFiles += 1
                continue
            }
            if scope == .unused, entry.lastUsed >= unusedCutoff { continue }
            if let url = try? ProxyMediaManager.cachedProxyURL(for: entry.cacheKey) {
                removedBytes += entry.byteCount
                ProxyMediaManager.removeProxy(at: url)
            }
            index.entries[entry.cacheKey] = nil
            removedFiles += 1
        }
        try removeIncompleteFiles()
        try saveIndex()
        return MediaCacheClearResult(
            removedByteCount: removedBytes,
            removedFileCount: removedFiles,
            retainedActiveFileCount: retainedActiveFiles
        )
    }

    func removeProxy(cacheKey: UUID?) throws {
        guard let cacheKey else { return }
        try loadIndexIfNeeded()
        guard inFlight[cacheKey] == nil, !allProtectedKeys.contains(cacheKey) else {
            pendingRemoval.insert(cacheKey)
            return
        }
        ProxyMediaManager.removeCachedProxy(for: cacheKey)
        index.entries[cacheKey] = nil
        try saveIndex()
    }

    private func removePendingProxies() throws {
        guard hasLoadedIndex else { return }
        let removable = pendingRemoval.filter {
            inFlight[$0] == nil && !allProtectedKeys.contains($0)
        }
        for cacheKey in removable {
            ProxyMediaManager.removeCachedProxy(for: cacheKey)
            index.entries[cacheKey] = nil
            pendingRemoval.remove(cacheKey)
        }
        try saveIndex()
    }

    @discardableResult
    func enforceLimits(
        additionalProtectedKeys: Set<UUID> = []
    ) async throws -> MediaCacheClearResult {
        try loadIndexIfNeeded()
        reconcileIndex()
        try removeIncompleteFiles()
        let protectedKeys = allProtectedKeys.union(additionalProtectedKeys)
        var totalBytes = index.entries.values.reduce(0) { $0 + $1.byteCount }
        var availableBytes = try availableCapacity()
        var removedBytes: Int64 = 0
        var removedFiles = 0
        let inFlightKeys = Set(inFlight.keys)
        let removals = MediaCacheEvictionPolicy.keysToRemove(
            candidates: index.entries.values.map {
                MediaCacheEvictionCandidate(
                    cacheKey: $0.cacheKey,
                    byteCount: $0.byteCount,
                    lastUsed: $0.lastUsed
                )
            },
            protectedKeys: protectedKeys.union(inFlightKeys),
            totalByteCount: totalBytes,
            availableByteCount: availableBytes,
            maximumByteCount: Self.maximumByteCount,
            minimumAvailableByteCount: Self.minimumAvailableByteCount
        )

        for cacheKey in removals {
            guard let entry = index.entries[cacheKey] else { continue }
            if let url = try? ProxyMediaManager.cachedProxyURL(for: entry.cacheKey) {
                ProxyMediaManager.removeProxy(at: url)
            }
            index.entries[entry.cacheKey] = nil
            totalBytes -= entry.byteCount
            availableBytes += entry.byteCount
            removedBytes += entry.byteCount
            removedFiles += 1
        }
        if availableBytes < Self.minimumAvailableByteCount,
           let cacheKey = additionalProtectedKeys.first,
           let entry = index.entries[cacheKey] {
            if let url = try? ProxyMediaManager.cachedProxyURL(for: cacheKey) {
                ProxyMediaManager.removeProxy(at: url)
            }
            index.entries[cacheKey] = nil
            removedBytes += entry.byteCount
            removedFiles += 1
            try saveIndex()
            throw MediaCacheError.insufficientDiskSpace
        }
        try saveIndex()
        return MediaCacheClearResult(
            removedByteCount: removedBytes,
            removedFileCount: removedFiles,
            retainedActiveFileCount: protectedKeys.count
        )
    }

    private var allProtectedKeys: Set<UUID> {
        protectedKeysByOwner.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    }

    private func loadIndexIfNeeded() throws {
        guard !hasLoadedIndex else { return }
        hasLoadedIndex = true
        let url = try indexURL()
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Index.self, from: data) {
            index = decoded
        }
        reconcileIndex()
        try removeIncompleteFiles()
        try saveIndex()
    }

    private func reconcileIndex() {
        for entry in Array(index.entries.values) {
            guard let url = try? ProxyMediaManager.cachedProxyURL(for: entry.cacheKey),
                  FileManager.default.fileExists(atPath: url.path),
                  fileByteCount(at: url) > 0 else {
                index.entries[entry.cacheKey] = nil
                continue
            }
            index.entries[entry.cacheKey]?.byteCount = fileByteCount(at: url)
        }
        guard let directory = try? ProxyMediaManager.cacheDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for url in urls where url.pathExtension.caseInsensitiveCompare("mp4") == .orderedSame {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let cacheKey = UUID(uuidString: stem), index.entries[cacheKey] == nil else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            index.entries[cacheKey] = Entry(
                cacheKey: cacheKey,
                fingerprint: SourceMediaFingerprint(
                    fileSize: -1,
                    modificationTime: -1,
                    proxyFormatVersion: -1
                ),
                byteCount: Int64(values?.fileSize ?? 0),
                lastUsed: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    private func validProxyURL(for cacheKey: UUID) -> URL? {
        guard let url = try? ProxyMediaManager.cachedProxyURL(for: cacheKey),
              FileManager.default.fileExists(atPath: url.path),
              fileByteCount(at: url) > 0 else { return nil }
        return url
    }

    private func fileByteCount(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func availableCapacity() throws -> Int64 {
        let directory = try ProxyMediaManager.cacheDirectory()
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    private func removeIncompleteFiles() throws {
        let directory = try ProxyMediaManager.cacheDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.lastPathComponent.contains(".partial.") {
            let prefix = String(url.lastPathComponent.prefix(36))
            if let cacheKey = UUID(uuidString: prefix), inFlight[cacheKey] != nil { continue }
            ProxyMediaManager.removeProxy(at: url)
        }
    }

    private func indexURL() throws -> URL {
        try ProxyMediaManager.cacheDirectory().appendingPathComponent("cache-index.json")
    }

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL(), options: .atomic)
    }
}
