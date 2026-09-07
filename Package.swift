// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Compile the production file-operation code without launching the macOS app.
let sources = ["MediaFileTransfer.swift", "ImportedFileHandling.swift", "MediaFileReference.swift", "TrackMixSettings.swift", "TrackMixProcessor.swift", "MixerPlayheadSlider.swift"]
let sourceDirectory = "Trimato/Trimato"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let excluded = (try? FileManager.default.contentsOfDirectory(atPath:
    root.appendingPathComponent(sourceDirectory).path))?.filter { !sources.contains($0) } ?? []
let package = Package(
    name: "TrimatoMediaVerification",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TrimatoMediaSupport", path: sourceDirectory, exclude: excluded,
                sources: sources, swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TrimatoMediaSupportTests", dependencies: ["TrimatoMediaSupport"],
                    path: "BackgroundTests", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
