import AppKit
import Combine

@MainActor
final class CaptionEditorWindowCoordinator: ObservableObject {
    private enum PresentationState {
        case closed
        case opening
        case open
        case closing
    }

    nonisolated let objectWillChange = ObservableObjectPublisher()
    private weak var controller: ProjectController?
    private var windowController: CaptionEditorWindowController?
    private var presentationState = PresentationState.closed
    private var restoreEditorFocusAfterClose = false

    init(controller: ProjectController) {
        self.controller = controller
    }

    func openNew() {
        guard let controller, let range = controller.captionDraftRange,
              let parent = projectWindow else {
            controller?.presentedError = ProjectPresentedError(
                title: "Caption Needs In and Out Points",
                message: "Mark an In point and an Out point in the Editor before adding a caption."
            )
            return
        }
        open(cue: nil, range: range, parent: parent)
    }

    func open(cue: CaptionCue) {
        guard let parent = projectWindow else { return }
        open(cue: cue, range: ProjectTimeRange(start: cue.start, duration: cue.duration), parent: parent)
    }

    func close() {
        close(returningToEditor: true)
    }

    private func open(cue: CaptionCue?, range: ProjectTimeRange, parent: NSWindow) {
        guard presentationState == .closed, windowController == nil,
              parent.attachedSheet == nil, let controller else { return }
        presentationState = .opening
        restoreEditorFocusAfterClose = false
        controller.stopCaptionPlayback()
        let windowController = CaptionEditorWindowController(
            cue: cue,
            range: range,
            save: { [weak self, weak controller] text in
                guard let self, let controller else { return }
                do {
                    if var cue {
                        cue.text = text
                        cue.identifier = nil
                        cue.webVTTSettings = nil
                        try controller.updateCaptionCue(cue)
                    } else {
                        _ = try controller.addCaptionCue(start: range.start, end: range.end, text: text)
                        controller.clearCaptionMarkers()
                    }
                    self.close(returningToEditor: true)
                } catch {
                    self.windowController?.present(error)
                }
            },
            play: { [weak controller] in controller?.playCaptionRange(range) },
            cancel: { [weak self] in self?.close(returningToEditor: true) }
        )
        self.windowController = windowController
        controller.setCaptionEditorOpen(true)
        windowController.present(asSheetOf: parent) { [weak self, weak windowController] in
            guard let self, let windowController,
                  self.windowController === windowController else { return }
            let shouldRestoreEditorFocus = self.restoreEditorFocusAfterClose
            self.windowController = nil
            self.presentationState = .closed
            self.restoreEditorFocusAfterClose = false
            self.controller?.setCaptionEditorOpen(false)
            if shouldRestoreEditorFocus {
                self.controller?.requestEditorFocusRestore()
            }
        }
        if presentationState == .opening {
            presentationState = .open
        }
    }

    private func close(returningToEditor: Bool) {
        guard presentationState == .open, let windowController else { return }
        presentationState = .closing
        restoreEditorFocusAfterClose = returningToEditor
        controller?.stopCaptionPlayback()
        windowController.closeSheet()
    }

    private var projectWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow.sheetParent ?? keyWindow
        }
        if let mainWindow = NSApp.mainWindow {
            return mainWindow.sheetParent ?? mainWindow
        }
        return nil
    }
}

@MainActor
final class CaptionEditorWindowController: NSWindowController, NSTextViewDelegate {
    private let textView = NSTextView()
    private let save: (String) -> Void
    private let play: () -> Void
    private let cancel: () -> Void
    private let saveButton: NSButton
    private weak var parentWindow: NSWindow?

    init(
        cue: CaptionCue?,
        range: ProjectTimeRange,
        save: @escaping (String) -> Void,
        play: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.save = save
        self.play = play
        self.cancel = cancel
        saveButton = NSButton(title: cue == nil ? "Add Caption" : "Update Caption", target: nil, action: nil)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = cue == nil ? "New Caption" : "Edit Caption"
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityModal(true)
        super.init(window: panel)
        buildContent(cue: cue, range: range)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(asSheetOf parent: NSWindow, didEnd: @escaping () -> Void) {
        guard let window else { return }
        parentWindow = parent
        window.initialFirstResponder = textView
        window.makeFirstResponder(textView)
        parent.beginSheet(window) { [weak self] _ in
            self?.parentWindow = nil
            didEnd()
        }
    }

    func closeSheet() {
        guard let window, let parentWindow else { return }
        parentWindow.endSheet(window)
    }

    func present(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Caption Could Not Be Saved"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func buildContent(cue: CaptionCue?, range: ProjectTimeRange) {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: cue == nil ? "New Caption" : "Edit Caption")
        heading.font = .preferredFont(forTextStyle: .headline)

        let inRow = labeledRow("In", ProjectTimecodeFormatter.string(range.start))
        let outRow = labeledRow("Out", ProjectTimecodeFormatter.string(range.end))

        let captionLabel = NSTextField(labelWithString: "Caption Text")
        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.setAccessibilityElement(false)
        textView.string = cue?.text ?? ""
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        textView.setAccessibilityTitleUIElement(captionLabel)
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let insertMenu = NSPopUpButton()
        insertMenu.addItems(withTitles: ["Insert Description", "Music Description", "Sound Description", "Lyrics"])
        insertMenu.target = self
        insertMenu.action = #selector(insertDescription(_:))
        insertMenu.selectItem(at: 0)

        let playButton = NSButton(title: "Play Selection", target: self, action: #selector(playPressed))
        playButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = !(cue?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let times = NSStackView(views: [inRow, outRow])
        times.orientation = .horizontal
        times.spacing = 24
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [playButton, insertMenu, spacer, cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [heading, times, captionLabel, textScroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.defaultButtonCell = saveButton.cell as? NSButtonCell
    }

    private func labeledRow(_ label: String, _ value: String) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .preferredFont(forTextStyle: .body)
        labelField.setAccessibilityElement(false)
        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueField.setAccessibilityTitleUIElement(labelField)
        valueField.setAccessibilityValue(value)
        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    func textDidChange(_ notification: Notification) {
        saveButton.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func savePressed() { save(textView.string) }
    @objc private func playPressed() { play() }
    @objc private func cancelPressed() { cancel() }

    @objc private func insertDescription(_ sender: NSPopUpButton) {
        let insertion: String
        switch sender.indexOfSelectedItem {
        case 1: insertion = "[music description]"
        case 2: insertion = "[sound description]"
        case 3: insertion = "♪ lyrics ♪"
        default: return
        }
        textView.insertText(insertion, replacementRange: textView.selectedRange())
        sender.selectItem(at: 0)
        window?.makeFirstResponder(textView)
    }
}
