import AppKit
import SwiftUI
import Foundation
@testable import Trimato

@main struct WorkspaceFullScreenCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { print("FAIL:", error.localizedDescription); exit(1) }
        }
        app.run()
    }
    @MainActor static func check() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var definition = GeneratorDefinition()
        definition.width = 320; definition.height = 180; definition.duration = ProjectTime(seconds: 3)
        let asset = definition.assetRecord()
        var project = TrimatoProject(name: "Full-screen stability check")
        project.media = [asset]
        _ = try project.append(asset: asset)
        let nativeOnly = ProcessInfo.processInfo.environment["TRIMATO_FULLSCREEN_NATIVE_ONLY"] == "1"
        let content = nativeOnly ? AnyView(Text("Native window transition check").frame(maxWidth: .infinity, maxHeight: .infinity)) : AnyView(EditorWorkspaceView(document: ProjectDocument(project: project)))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 120, y: 100, width: 1000, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = host
        if nativeOnly { window.setFrame((window.screen ?? NSScreen.main)!.visibleFrame, display: false) }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))
        let screen = (window.screen ?? NSScreen.main)!
        precondition(window.frame == screen.visibleFrame, "Project did not fill the usable screen on attachment")
        print("Initial workspace fills usable screen", Int(window.frame.width), Int(window.frame.height))
        if !nativeOnly {
            for player in findPlayers(host) {
                print("Initial preview status", player.playerLayer.player?.currentItem?.status.rawValue ?? -1,
                      "size", Int(player.bounds.width), Int(player.bounds.height))
            }
        }
        let original = window.frame
        let transitions = FullScreenTransitions()
        let center = NotificationCenter.default
        center.addObserver(transitions, selector: #selector(FullScreenTransitions.didEnter), name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(transitions, selector: #selector(FullScreenTransitions.didExit), name: NSWindow.didExitFullScreenNotification, object: window)
        defer { center.removeObserver(transitions) }
        for cycle in 1...2 {
            print("Toggle fullscreen; active", app.isActive, "key", window.isKeyWindow, "visible", window.isVisible, "style", window.styleMask.rawValue)
            window.toggleFullScreen(nil)
            for _ in 0..<400 where transitions.entries < cycle { try await Task.sleep(for: .milliseconds(25)) }
            precondition(transitions.entries == cycle && window.styleMask.contains(.fullScreen), "Native full-screen entry failed")
            try await Task.sleep(for: .seconds(1))
            host.layoutSubtreeIfNeeded()
            if !nativeOnly { verifyPanes(host) }
            let fullFrame = window.frame
            let companion = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 680),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            companion.isReleasedWhenClosed = false
            companion.collectionBehavior.insert(.fullScreenAuxiliary)
            AuthoringWindowArrangement.shared.place(companion, beside: window)
            precondition(window.frame == fullFrame, "Companion arrangement changed full-screen project geometry")
            AuthoringWindowArrangement.shared.release(companion)
            companion.close()
            print("Toggle fullscreen; active", app.isActive, "key", window.isKeyWindow, "visible", window.isVisible, "style", window.styleMask.rawValue)
            window.toggleFullScreen(nil)
            for _ in 0..<400 where transitions.exits < cycle { try await Task.sleep(for: .milliseconds(25)) }
            precondition(transitions.exits == cycle && !window.styleMask.contains(.fullScreen), "Native full-screen exit failed")
            try await Task.sleep(for: .seconds(1))
            host.layoutSubtreeIfNeeded()
            if !nativeOnly { verifyPanes(host) }
            precondition(window.frame == original, "Full-screen exit did not restore usable-screen geometry")
            let players = findPlayers(host)
            precondition(nativeOnly || !players.isEmpty && players.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
            print("PASS cycle", cycle, nativeOnly ? "native full-screen entry/exit" :
                  "native full-screen entry/exit, pane names, companion isolation and video dimensions")
        }
        print("PASS: default window size and repeated native full-screen transitions. Live VoiceOver speech remains unverified.")
    }
    @MainActor static func attribute(_ item: NSObject, _ name: String) -> Any? {
        item.responds(to: NSSelectorFromString(name)) ? item.value(forKey: name) : nil
    }
    @MainActor static func descendants(_ item: NSObject) -> [NSObject] {
        [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(descendants)
    }
    @MainActor static func verifyPanes(_ host: NSView) {
        let elements = descendants(host)
        for name in ["Project", "Editor", "Timeline"] {
            precondition(elements.contains { attribute($0, "accessibilityLabel") as? String == name }, "Missing native pane: \(name)")
        }
    }
    @MainActor static func findPlayers(_ view: NSView) -> [PlayerNSView] {
        (view as? PlayerNSView).map { [$0] } ?? view.subviews.flatMap(findPlayers)
    }
}

@MainActor final class FullScreenTransitions: NSObject {
    var entries = 0
    var exits = 0
    @objc func didEnter(_ notification: Notification) { entries += 1; print("Native didEnterFullScreen", entries) }
    @objc func didExit(_ notification: Notification) { exits += 1; print("Native didExitFullScreen", exits) }
}
