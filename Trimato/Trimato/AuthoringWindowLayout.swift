import AppKit

/// Window geometry only. This does not change keyboard or accessibility focus.
struct AuthoringWindowLayout {
    struct Frames: Equatable {
        let project: CGRect
        let tool: CGRect
    }

    static func frames(project: CGRect, toolSize: CGSize, screen: CGRect,
                       minimumProjectWidth: CGFloat = 800) -> Frames? {
        let gap: CGFloat = 12
        guard toolSize.width + minimumProjectWidth + gap <= screen.width,
              toolSize.height <= screen.height else { return nil }
        let toolX = screen.maxX - toolSize.width
        let availableProject = CGRect(x: screen.minX, y: screen.minY,
                                      width: toolX - gap - screen.minX, height: screen.height)
        var projectFrame = project
        projectFrame.size.width = min(max(project.width, minimumProjectWidth), availableProject.width)
        projectFrame.size.height = min(project.height, screen.height)
        projectFrame.origin.x = min(max(project.minX, availableProject.minX), availableProject.maxX - projectFrame.width)
        projectFrame.origin.y = min(max(project.minY, screen.minY), screen.maxY - projectFrame.height)
        let tool = CGRect(x: toolX, y: screen.maxY - toolSize.height, width: toolSize.width, height: toolSize.height)
        return Frames(project: projectFrame, tool: tool)
    }
}

/// Keeps companion windows outside the project. Restores only geometry that the
/// user has not subsequently changed, and waits until the last companion closes.
@MainActor
final class AuthoringWindowArrangement {
    static let shared = AuthoringWindowArrangement()
    private weak var projectWindow: NSWindow?
    private var originalFrame: CGRect?
    private var arrangedFrame: CGRect?
    private var tools: [ObjectIdentifier: WeakWindow] = [:]
    private struct WeakWindow { weak var window: NSWindow? }

    func place(_ tool: NSWindow, beside project: NSWindow?) {
        guard let project, let screen = project.screen ?? NSScreen.main else { return }
        tools = tools.filter { $0.value.window != nil }
        if projectWindow !== project {
            restore()
            projectWindow = project
            originalFrame = project.frame
        }
        tools[ObjectIdentifier(tool)] = WeakWindow(window: tool)
        let width = tools.values.compactMap { $0.window?.frame.width }.max() ?? tool.frame.width
        if let frames = AuthoringWindowLayout.frames(
            project: project.frame, toolSize: CGSize(width: width, height: min(tool.frame.height, screen.visibleFrame.height)),
            screen: screen.visibleFrame, minimumProjectWidth: max(800, project.minSize.width)
        ) {
            project.setFrame(frames.project, display: true)
            arrangedFrame = project.frame
            for entry in tools.values {
                guard let window = entry.window else { continue }
                var frame = window.frame
                frame.size.height = min(frame.height, screen.visibleFrame.height)
                frame.origin = CGPoint(x: frames.tool.minX, y: screen.visibleFrame.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        } else if let otherScreen = NSScreen.screens.first(where: {
            $0 !== screen && $0.visibleFrame.width >= tool.frame.width && $0.visibleFrame.height >= tool.frame.height
        }) {
            tool.setFrameOrigin(CGPoint(x: otherScreen.visibleFrame.minX,
                                       y: otherScreen.visibleFrame.maxY - tool.frame.height))
        }
    }

    func release(_ tool: NSWindow?) {
        guard let tool else { return }
        tools.removeValue(forKey: ObjectIdentifier(tool))
        tools = tools.filter { $0.value.window != nil }
        if tools.isEmpty { restore() }
    }

    private func restore() {
        if let projectWindow, let originalFrame, projectWindow.frame == arrangedFrame,
           projectWindow.isVisible {
            projectWindow.setFrame(originalFrame, display: true)
        }
        projectWindow = nil
        originalFrame = nil
        arrangedFrame = nil
        tools.removeAll()
    }
}
