import Foundation

enum RelatedExportFileWriter {
    static func write(_ data: Data, to relatedURL: URL, relatedTo primaryURL: URL) throws {
        try Task.checkCancellation()
        let presenter = RelatedExportFilePresenter(
            primaryURL: primaryURL,
            relatedURL: relatedURL
        )
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: relatedURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try Task.checkCancellation()
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

private final class RelatedExportFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let primaryPresentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(primaryURL: URL, relatedURL: URL) {
        primaryPresentedItemURL = primaryURL
        presentedItemURL = relatedURL
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
    }
}
