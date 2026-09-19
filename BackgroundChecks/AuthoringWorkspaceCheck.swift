import AppKit
import AVFoundation
import SwiftUI
@testable import Trimato

@main struct AuthoringWorkspaceCheck {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 949),
                       CGRect(x: -1280, y: 40, width: 1280, height: 760)] {
            let result = AuthoringWindowLayout.frames(project: screen,
                toolSize: CGSize(width: 440, height: 680), screen: screen)!
            precondition(screen.contains(result.project) && screen.contains(result.tool))
            precondition(!result.project.intersects(result.tool))
            precondition(result.project.width >= 800)
        }
        precondition(AuthoringWindowLayout.frames(project: .zero,
            toolSize: CGSize(width: 440, height: 700),
            screen: CGRect(x: 0, y: 0, width: 1024, height: 768)) == nil)
        print("PASS: window placement fits standard and negative-origin displays without overlap")

        let controller = ProjectController(document: ProjectDocument(project: TrimatoProject(name: "Authoring check")))
        let player = ProjectPlayerViewModel()
        controller.installProjectPlayer(player)
        let session = ProjectRecordingSession(controller: controller, purpose: .audioDescription)
        precondition(player.authoringPlaybackID == session.id && !player.canControlPlayback)
        player.endAuthoringPlayback(id: UUID(), at: .zero)
        precondition(player.authoringPlaybackID == session.id, "A stale session must not release playback ownership")

        let host = NSHostingView(rootView: ProjectRecordingView(session: session))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        precondition(findPlayers(host).isEmpty, "The authoring window must not contain a video player")
        precondition(host.fittingSize.width <= 441, "Authoring controls must fit the compact width")
        try snapshot(host, name: "describer")
        print("PASS: Describer uses a compact native window without a duplicate video view")

        let preview = NSHostingView(rootView: RecordingEditorPreview(session: session, project: controller.project))
        let editorWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 720),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentView = preview
        editorWindow.orderBack(nil)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); preview.layoutSubtreeIfNeeded() }
        let displays = findPlayers(preview)
        precondition(displays.count == 1 && displays[0].playerLayer.player === session.player)
        precondition(displays[0].bounds.width > 700 && displays[0].bounds.height > 500)
        print("PASS: Editor displays the actual session player in a scaling preview")
        session.close()
        precondition(player.authoringPlaybackID == nil)
        window.close(); editorWindow.close()

        let voiceSession = ProjectRecordingSession(controller: controller, purpose: .voiceOver)
        let voiceHost = NSHostingView(rootView: ProjectRecordingView(session: voiceSession))
        let voiceWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 600),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        voiceWindow.isReleasedWhenClosed = false
        voiceWindow.contentView = voiceHost
        voiceWindow.orderBack(nil)
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); voiceHost.layoutSubtreeIfNeeded() }
        precondition(findPlayers(voiceHost).isEmpty)
        try snapshot(voiceHost, name: "voicer")
        voiceSession.close(); voiceWindow.close()

        let mixer = MixerSession(controller: controller, player: player)
        let mixerHost = NSHostingView(rootView: MixerView(session: mixer, player: player))
        let mixerWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 700),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        mixerWindow.isReleasedWhenClosed = false
        mixerWindow.contentView = mixerHost
        mixerWindow.orderBack(nil)
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); mixerHost.layoutSubtreeIfNeeded() }
        precondition(findPlayers(mixerHost).isEmpty)
        precondition(mixerHost.fittingSize.width <= 441)
        try snapshot(mixerHost, name: "mixer")
        let screen = NSScreen.main!.visibleFrame
        let projectWindow = NSWindow(contentRect: screen, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        projectWindow.isReleasedWhenClosed = false
        projectWindow.setFrame(screen, display: false)
        projectWindow.orderBack(nil)
        let original = projectWindow.frame
        AuthoringWindowArrangement.shared.place(mixerWindow, beside: projectWindow)
        precondition(!projectWindow.frame.intersects(mixerWindow.frame))
        AuthoringWindowArrangement.shared.release(mixerWindow)
        precondition(projectWindow.frame == original)
        AuthoringWindowArrangement.shared.place(mixerWindow, beside: projectWindow)
        var userFrame = projectWindow.frame; userFrame.size.height -= 20
        projectWindow.setFrame(userFrame, display: false)
        userFrame = projectWindow.frame
        AuthoringWindowArrangement.shared.release(mixerWindow)
        precondition(projectWindow.frame == userFrame, "Do not overwrite a user's window arrangement")
        projectWindow.close(); mixerWindow.close()
        print("PASS: Voicer and Mixer have no video views; window restoration respects user changes")
        print("PASS: closing authoring releases project playback ownership")
    }

    @MainActor static func snapshot(_ view: NSView, name: String) throws {
        guard ProcessInfo.processInfo.environment["TRIMATO_CAPTURE_LAYOUTS"] == "1", let window = view.window else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "/tmp/trimato-authoring-\(name).png"]
        try capture.run()
        capture.waitUntilExit()
        precondition(capture.terminationStatus == 0, "Native layout capture failed")
    }

    @MainActor static func findPlayers(_ view: NSView) -> [PlayerNSView] {
        (view as? PlayerNSView).map { [$0] } ?? view.subviews.flatMap(findPlayers)
    }
}
