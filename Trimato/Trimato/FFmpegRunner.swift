import Foundation

enum FFmpegTool: String {
    case ffmpeg
    case ffprobe
}

struct FFmpegCommandError: LocalizedError {
    let tool: FFmpegTool
    let status: Int32
    let diagnostics: String

    var errorDescription: String? {
        let finalLine = diagnostics
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init) ?? "Unknown error"
        return "\(tool.rawValue) failed: \(finalLine)"
    }

    var isVideoToolboxUnavailable: Bool {
        diagnostics.contains("Cannot create compression session") ||
            diagnostics.contains("Video encoder not available")
    }
}

nonisolated final class FFmpegProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func store(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancellationRequested
        lock.unlock()
        if shouldTerminate {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    var wasCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

private nonisolated final class FFmpegOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var unfinishedLine = ""
    private let duration: Double?
    private let progress: (@MainActor @Sendable (Double) -> Void)?
    private let outputLine: (@Sendable (String) -> Void)?

    init(
        duration: Double?,
        progress: (@MainActor @Sendable (Double) -> Void)?,
        outputLine: (@Sendable (String) -> Void)?
    ) {
        self.duration = duration
        self.progress = progress
        self.outputLine = outputLine
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        let text = unfinishedLine + String(decoding: newData, as: UTF8.self)
        var lines = text.components(separatedBy: .newlines)
        unfinishedLine = lines.popLast() ?? ""
        lock.unlock()

        for line in lines {
            outputLine?(line)
            if let duration, duration > 0, let progress {
                FFmpegRunner.parseProgressLine(line, duration: duration) { value in
                    Task { @MainActor in progress(value) }
                }
            }
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private actor FFmpegExecutionGate {
    static let shared = FFmpegExecutionGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard isOccupied else {
            isOccupied = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isOccupied = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

struct FFmpegRunner {
    nonisolated struct Result: Sendable {
        let standardOutput: Data
        let standardError: String
    }

    static func bundledURL(for tool: FFmpegTool, bundle: Bundle = .main) -> URL? {
        let candidates = [
            bundle.url(forResource: tool.rawValue, withExtension: nil),
            bundle.url(forResource: tool.rawValue, withExtension: nil, subdirectory: "Tools"),
            bundle.url(forResource: tool.rawValue, withExtension: nil, subdirectory: "Resources/Tools"),
            bundle.resourceURL?.appendingPathComponent("Tools/\(tool.rawValue)")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(
        tool: FFmpegTool,
        arguments: [String],
        progress: (@MainActor @Sendable (Double) -> Void)? = nil,
        expectedDuration: Double? = nil,
        outputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try await FFmpegExecutionGate.shared.acquire()
        do {
            try Task.checkCancellation()
            let result = try await runProcess(
                tool: tool,
                arguments: arguments,
                progress: progress,
                expectedDuration: expectedDuration,
                outputLine: outputLine
            )
            await FFmpegExecutionGate.shared.release()
            return result
        } catch {
            await FFmpegExecutionGate.shared.release()
            throw error
        }
    }

    private static func runProcess(
        tool: FFmpegTool,
        arguments: [String],
        progress: (@MainActor @Sendable (Double) -> Void)?,
        expectedDuration: Double?,
        outputLine: (@Sendable (String) -> Void)?
    ) async throws -> Result {
        guard let executableURL = bundledURL(for: tool) else {
            throw MediaSourceError.bundledToolsMissing
        }

        let box = FFmpegProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                box.store(process)
                let collector = FFmpegOutputCollector(
                    duration: expectedDuration,
                    progress: progress,
                    outputLine: outputLine
                )
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.append(handle.availableData)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    let output = collector.snapshot()
                    let diagnostics = String(decoding: errorData, as: UTF8.self)

                    if box.wasCancellationRequested {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        continuation.resume(throwing: FFmpegCommandError(
                            tool: tool,
                            status: process.terminationStatus,
                            diagnostics: diagnostics
                        ))
                    } else {
                        continuation.resume(returning: Result(
                            standardOutput: output,
                            standardError: diagnostics
                        ))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func parseProgress(
        _ data: Data,
        duration: Double,
        handler: @Sendable (Double) -> Void
    ) {
        guard duration > 0 else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \Character.isNewline) {
            parseProgressLine(String(line), duration: duration, handler: handler)
        }
    }

    nonisolated static func parseProgressLine(
        _ line: String,
        duration: Double,
        handler: @Sendable (Double) -> Void
    ) {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        if parts[0] == "out_time_us", let microseconds = Double(parts[1]) {
            handler(min(max(microseconds / 1_000_000 / duration, 0), 1))
        } else if parts[0] == "progress", parts[1] == "end" {
            handler(1)
        }
    }
}
