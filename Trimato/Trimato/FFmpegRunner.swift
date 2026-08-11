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

    func store(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }
}

private nonisolated final class FFmpegOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var unfinishedLine = ""
    private let duration: Double?
    private let progress: (@MainActor @Sendable (Double) -> Void)?

    init(duration: Double?, progress: (@MainActor @Sendable (Double) -> Void)?) {
        self.duration = duration
        self.progress = progress
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        let text = unfinishedLine + String(decoding: newData, as: UTF8.self)
        var lines = text.components(separatedBy: .newlines)
        unfinishedLine = lines.popLast() ?? ""
        lock.unlock()

        guard let duration, duration > 0, let progress else { return }
        for line in lines {
            FFmpegRunner.parseProgressLine(line, duration: duration) { value in
                Task { @MainActor in progress(value) }
            }
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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
        expectedDuration: Double? = nil
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
                    progress: progress
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

                    if Task.isCancelled || process.terminationReason == .uncaughtSignal {
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
            box.terminate()
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
