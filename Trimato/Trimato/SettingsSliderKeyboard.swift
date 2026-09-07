import AppKit
import Combine

@MainActor
final class SettingsSliderKeyboard: ObservableObject {
    nonisolated static let identifier = "trimato.settings.microphone-volume"
    private var monitor: Any?
    private let targetIdentifier: String
    init(identifier: String = SettingsSliderKeyboard.identifier) { targetIdentifier = identifier }
    func start() {
        guard monitor == nil else { return }
        let identifier = targetIdentifier
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handle(event, focused: NSApp.accessibilityFocusedUIElement as? NSObject, identifier: identifier)
        }
    }

    static func handle(_ event: NSEvent, focused: NSObject?, identifier: String = SettingsSliderKeyboard.identifier) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              event.keyCode == 126 || event.keyCode == 125 else { return event }
        var candidate = focused
        var visited = Set<ObjectIdentifier>()
        while let element = candidate, visited.insert(ObjectIdentifier(element)).inserted {
            let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
            if element.responds(to: identifierSelector),
               element.value(forKey: "accessibilityIdentifier") as? String == identifier {
                let action = NSSelectorFromString(event.keyCode == 126 ? "accessibilityPerformIncrement" : "accessibilityPerformDecrement")
                guard element.responds(to: action) else { return event }
                typealias NativeAdjustment = @convention(c) (AnyObject, Selector) -> Bool
                let adjust = unsafeBitCast(element.method(for: action), to: NativeAdjustment.self)
                _ = adjust(element, action)
                return nil
            }
            let parentSelector = NSSelectorFromString("accessibilityParent")
            candidate = element.responds(to: parentSelector)
                ? element.perform(parentSelector)?.takeUnretainedValue() as? NSObject : nil
        }
        return event
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
