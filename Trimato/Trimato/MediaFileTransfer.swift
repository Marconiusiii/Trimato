import Foundation
import CryptoKit

nonisolated struct MediaFileHandlingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct MediaTransferResult: Sendable {
    var destinations: [UUID: URL]
    var created: [URL]
    var originals: [URL]
    var removals: [URL: URL] = [:]
}

nonisolated struct MediaTransferProgress: Sendable {
    let fraction: Double
    let detail: String
}

nonisolated enum MediaFileTransfer {
    static func checksum(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize()
    }

    static func prepare(_ sources: [UUID: URL], in folder: URL,
                        progress: @escaping @Sendable (MediaTransferProgress) -> Void) async throws -> MediaTransferResult {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            var result = MediaTransferResult(destinations: [:], created: [], originals: [])
            var transferred: [String: URL] = [:]
            do {
                for (index, entry) in sources.sorted(by: { $0.key.uuidString < $1.key.uuidString }).enumerated() {
                    try Task.checkCancellation()
                    let (id, source) = entry
                    let canonical = source.resolvingSymlinksInPath().standardizedFileURL
                    guard FileManager.default.isReadableFile(atPath: canonical.path),
                          try canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw MediaFileHandlingError(message: "\(source.lastPathComponent): Source Missing or access unavailable.")
                    }
                    let key = canonical.path
                    let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                    if key.hasPrefix(root) {
                        let managed = source.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") ? source : canonical
                        result.destinations[id] = managed
                        transferred[key] = managed
                        continue
                    }
                    if let existing = transferred[key] {
                        result.destinations[id] = existing
                        if result.removals[source] == nil {
                            result.originals.append(source)
                            result.removals[source] = existing
                        }
                        continue
                    }
                    var destination = folder.appendingPathComponent(source.lastPathComponent)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        destination = folder.appendingPathComponent(
                            "\(source.deletingPathExtension().lastPathComponent) \(suffix)"
                        ).appendingPathExtension(source.pathExtension)
                        suffix += 1
                    }
                    let staging = folder.appendingPathComponent(".trimato-transfer-\(UUID()).tmp")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    progress(.init(fraction: Double(index) / Double(max(sources.count, 1)), detail: "Copying \(source.lastPathComponent)"))
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: canonical, to: staging)
                    progress(.init(fraction: Double(index) / Double(max(sources.count, 1)), detail: "Verifying \(source.lastPathComponent)"))
                    guard try checksum(source) == checksum(staging) else {
                        throw MediaFileHandlingError(message: "\(source.lastPathComponent) changed while it was being copied. The original has been kept.")
                    }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: staging, to: destination)
                    result.created.append(destination)
                    result.originals.append(source)
                    result.removals[source] = destination
                    result.destinations[id] = destination
                    transferred[key] = destination
                    progress(.init(fraction: Double(index + 1) / Double(max(sources.count, 1)), detail: source.lastPathComponent))
                }
                try Task.checkCancellation()
                return result
            } catch {
                for url in result.created { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    static func removeOriginals(_ result: MediaTransferResult) async -> [String] {
        if Task.isCancelled {
            return result.removals.keys.map { "\($0.lastPathComponent): Removal was cancelled. The original has been kept." }
        }
        let work = Task.detached(priority: .utility) {
            var failures: [String] = []
            for (url, destination) in result.removals {
                if Task.isCancelled {
                    failures.append("\(url.lastPathComponent): Removal was cancelled. The original has been kept.")
                    continue
                }
                do {
                    guard try checksum(url) == checksum(destination) else {
                        throw MediaFileHandlingError(message: "The original changed after copying and has been kept.")
                    }
                    try FileManager.default.removeItem(at: url)
                }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            return failures
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }
}
