import SwiftUI

nonisolated enum ProjectFormatValidation {
    static let minimumDimension = 2
    static let maximumDimension = 8_192
    static let minimumFrameRate = 1.0
    static let maximumFrameRate = 240.0

    static func message(width: Int, height: Int, frameRate: Double) -> String? {
        guard (minimumDimension...maximumDimension).contains(width),
              (minimumDimension...maximumDimension).contains(height) else {
            return "Width and height must each be between 2 and 8,192 pixels."
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            return "Width and height must be even numbers so video encoders can use the project frame."
        }
        guard frameRate.isFinite,
              (minimumFrameRate...maximumFrameRate).contains(frameRate) else {
            return "Frame rate must be between 1 and 240 frames per second. Fractional rates such as 23.976 and 29.97 are allowed."
        }
        return nil
    }
}

nonisolated enum ProjectResolutionChoice: String, CaseIterable, Identifiable, Sendable {
    case hd
    case fullHD
    case qhd
    case ultraHD
    case verticalHD
    case verticalFullHD
    case verticalUltraHD
    case square
    case portraitFourByFive
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd: "1280 by 720, HD"
        case .fullHD: "1920 by 1080, Full HD"
        case .qhd: "2560 by 1440, QHD"
        case .ultraHD: "3840 by 2160, 4K UHD"
        case .verticalHD: "720 by 1280, vertical HD"
        case .verticalFullHD: "1080 by 1920, vertical Full HD"
        case .verticalUltraHD: "2160 by 3840, vertical 4K"
        case .square: "1080 by 1080, square"
        case .portraitFourByFive: "1080 by 1350, portrait 4 by 5"
        case .custom: "Custom dimensions"
        }
    }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .hd: (1_280, 720)
        case .fullHD: (1_920, 1_080)
        case .qhd: (2_560, 1_440)
        case .ultraHD: (3_840, 2_160)
        case .verticalHD: (720, 1_280)
        case .verticalFullHD: (1_080, 1_920)
        case .verticalUltraHD: (2_160, 3_840)
        case .square: (1_080, 1_080)
        case .portraitFourByFive: (1_080, 1_350)
        case .custom: nil
        }
    }

    static func selection(width: Int, height: Int) -> Self {
        allCases.first { choice in
            guard let dimensions = choice.dimensions else { return false }
            return dimensions.width == width && dimensions.height == height
        } ?? .custom
    }
}

nonisolated enum ProjectFrameRateChoice: String, CaseIterable, Identifiable, Sendable {
    case fps23_976
    case fps24
    case fps25
    case fps29_97
    case fps30
    case fps50
    case fps59_94
    case fps60
    case fps120
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fps23_976: "23.976 fps"
        case .fps24: "24 fps"
        case .fps25: "25 fps"
        case .fps29_97: "29.97 fps"
        case .fps30: "30 fps"
        case .fps50: "50 fps"
        case .fps59_94: "59.94 fps"
        case .fps60: "60 fps"
        case .fps120: "120 fps"
        case .custom: "Custom frame rate"
        }
    }

    var value: Double? {
        switch self {
        case .fps23_976: 24_000.0 / 1_001.0
        case .fps24: 24
        case .fps25: 25
        case .fps29_97: 30_000.0 / 1_001.0
        case .fps30: 30
        case .fps50: 50
        case .fps59_94: 60_000.0 / 1_001.0
        case .fps60: 60
        case .fps120: 120
        case .custom: nil
        }
    }

    static func selection(frameRate: Double) -> Self {
        allCases.first { choice in
            guard let value = choice.value else { return false }
            return abs(value - frameRate) < 0.001
        } ?? .custom
    }
}

nonisolated enum ProjectAspectRatioLock {
    static func dimensions(
        afterEditingWidth width: Int,
        currentHeight: Int,
        ratio: Double,
        isLocked: Bool
    ) -> (width: Int, height: Int) {
        guard isLocked, let height = height(forWidth: width, ratio: ratio) else {
            return (width, currentHeight)
        }
        return (width, height)
    }

    static func dimensions(
        afterEditingHeight height: Int,
        currentWidth: Int,
        ratio: Double,
        isLocked: Bool
    ) -> (width: Int, height: Int) {
        guard isLocked, let width = width(forHeight: height, ratio: ratio) else {
            return (currentWidth, height)
        }
        return (width, height)
    }

    static func height(forWidth width: Int, ratio: Double) -> Int? {
        nearestEvenDimension(Double(width) / ratio)
    }

    static func width(forHeight height: Int, ratio: Double) -> Int? {
        nearestEvenDimension(Double(height) * ratio)
    }

    private static func nearestEvenDimension(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value < Double(Int.max - 2) else { return nil }
        return max(Int((value / 2).rounded()) * 2, 2)
    }
}

struct ProjectCreationView: View {
    @ObservedObject var controller: ProjectController
    let finish: () -> Void

    @State private var name: String
    @State private var mode: ProjectFormatMode
    @State private var resolutionChoice: ProjectResolutionChoice
    @State private var customWidth: Int
    @State private var customHeight: Int
    @State private var hasPreparedCustomDimensions: Bool
    @State private var isAspectRatioLocked: Bool
    @State private var lockedAspectRatio: Double
    @State private var frameRateChoice: ProjectFrameRateChoice
    @State private var customFrameRate: Double
    @State private var hasPreparedCustomFrameRate: Bool
    @State private var usesTargetDuration: Bool
    @State private var targetSeconds: Double
    @State private var validationError: String?
    @AccessibilityFocusState private var headingFocused: Bool
    @AccessibilityFocusState private var validationErrorFocused: Bool
    @AccessibilityFocusState private var focusedPicker: PickerFocus?

    private enum PickerFocus: Hashable {
        case resolution
        case frameRate
    }

    init(controller: ProjectController, finish: @escaping () -> Void) {
        self.controller = controller
        self.finish = finish
        let project = controller.project
        _name = State(initialValue: project.name)
        _mode = State(initialValue: project.format.mode)
        let initialWidth = project.format.width ?? 1_920
        let initialHeight = project.format.height ?? 1_080
        let initialFrameRate = project.format.frameRate ?? 30
        let initialResolutionChoice = ProjectResolutionChoice.selection(
            width: initialWidth,
            height: initialHeight
        )
        let initialFrameRateChoice = ProjectFrameRateChoice.selection(frameRate: initialFrameRate)
        _resolutionChoice = State(initialValue: initialResolutionChoice)
        _customWidth = State(initialValue: initialWidth)
        _customHeight = State(initialValue: initialHeight)
        _hasPreparedCustomDimensions = State(initialValue: initialResolutionChoice == .custom)
        _isAspectRatioLocked = State(initialValue: true)
        _lockedAspectRatio = State(initialValue: Double(initialWidth) / Double(max(initialHeight, 1)))
        _frameRateChoice = State(initialValue: initialFrameRateChoice)
        _customFrameRate = State(initialValue: initialFrameRate)
        _hasPreparedCustomFrameRate = State(initialValue: initialFrameRateChoice == .custom)
        _usesTargetDuration = State(initialValue: project.targetDuration != nil)
        _targetSeconds = State(initialValue: project.targetDuration?.seconds ?? 60)
        _validationError = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Settings")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)

            Form {
                TextField("Project Name", text: $name)

                Picker("Project Format", selection: $mode) {
                    Text("Automatic from First Clip").tag(ProjectFormatMode.automatic)
                    Text("Custom").tag(ProjectFormatMode.custom)
                }
                .pickerStyle(.radioGroup)

                if mode == .custom {
                    Picker("Resolution", selection: resolutionSelection) {
                        ForEach(ProjectResolutionChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityFocused($focusedPicker, equals: .resolution)

                    if resolutionChoice == .custom {
                        TextField("Width", value: customWidthBinding, format: .number)
                        TextField("Height", value: customHeightBinding, format: .number)
                        Toggle("Lock aspect ratio", isOn: aspectRatioLockBinding)
                            .toggleStyle(.checkbox)
                    }

                    Picker("Frame rate", selection: frameRateSelection) {
                        ForEach(ProjectFrameRateChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityFocused($focusedPicker, equals: .frameRate)

                    if frameRateChoice == .custom {
                        TextField("Custom frame rate", value: $customFrameRate, format: .number)
                    }

                    Text("Choose a preset or enter custom even dimensions from 2 through 8,192 pixels and a custom frame rate from 1 through 240 fps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let validationError {
                        Text(validationError)
                            .foregroundStyle(.red)
                            .accessibilityFocused($validationErrorFocused)
                    }
                }

                Toggle("Use Target Duration", isOn: $usesTargetDuration)
                if usesTargetDuration {
                    TextField("Target Duration in Seconds", value: $targetSeconds, format: .number)
                }
            }

            HStack {
                Spacer()
                Button("Save Project Settings") {
                    if mode == .custom,
                       let message = ProjectFormatValidation.message(
                           width: resolvedWidth,
                           height: resolvedHeight,
                           frameRate: resolvedFrameRate
                        ) {
                        validationError = message
                        DispatchQueue.main.async { validationErrorFocused = true }
                        return
                    }
                    validationError = nil
                    let format = ProjectFormat(
                        mode: mode,
                        width: mode == .custom ? resolvedWidth : nil,
                        height: mode == .custom ? resolvedHeight : nil,
                        frameRate: mode == .custom ? resolvedFrameRate : nil
                    )
                    controller.updateProjectSettings(
                        name: name,
                        format: format,
                        targetDuration: usesTargetDuration ? ProjectTime(seconds: max(targetSeconds, 0.001)) : nil
                    )
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { headingFocused = true }
    }

    private var resolvedWidth: Int {
        resolutionChoice.dimensions?.width ?? customWidth
    }

    private var resolvedHeight: Int {
        resolutionChoice.dimensions?.height ?? customHeight
    }

    private var resolvedFrameRate: Double {
        frameRateChoice.value ?? customFrameRate
    }

    private var resolutionSelection: Binding<ProjectResolutionChoice> {
        Binding(
            get: { resolutionChoice },
            set: { choice in
                guard choice != resolutionChoice else { return }
                if choice == .custom, !hasPreparedCustomDimensions {
                    if let dimensions = resolutionChoice.dimensions {
                        customWidth = dimensions.width
                        customHeight = dimensions.height
                        lockedAspectRatio = Double(dimensions.width) / Double(dimensions.height)
                    }
                    hasPreparedCustomDimensions = true
                }
                resolutionChoice = choice
                validationError = nil
                restorePickerFocus(.resolution)
            }
        )
    }

    private var frameRateSelection: Binding<ProjectFrameRateChoice> {
        Binding(
            get: { frameRateChoice },
            set: { choice in
                guard choice != frameRateChoice else { return }
                if choice == .custom, !hasPreparedCustomFrameRate {
                    if let frameRate = frameRateChoice.value {
                        customFrameRate = frameRate
                    }
                    hasPreparedCustomFrameRate = true
                }
                frameRateChoice = choice
                validationError = nil
                restorePickerFocus(.frameRate)
            }
        )
    }

    private var customWidthBinding: Binding<Int> {
        Binding(
            get: { customWidth },
            set: { newWidth in
                let dimensions = ProjectAspectRatioLock.dimensions(
                    afterEditingWidth: newWidth,
                    currentHeight: customHeight,
                    ratio: lockedAspectRatio,
                    isLocked: isAspectRatioLocked
                )
                customWidth = dimensions.width
                customHeight = dimensions.height
            }
        )
    }

    private var customHeightBinding: Binding<Int> {
        Binding(
            get: { customHeight },
            set: { newHeight in
                let dimensions = ProjectAspectRatioLock.dimensions(
                    afterEditingHeight: newHeight,
                    currentWidth: customWidth,
                    ratio: lockedAspectRatio,
                    isLocked: isAspectRatioLocked
                )
                customWidth = dimensions.width
                customHeight = dimensions.height
            }
        )
    }

    private var aspectRatioLockBinding: Binding<Bool> {
        Binding(
            get: { isAspectRatioLocked },
            set: { isLocked in
                if isLocked, customWidth > 0, customHeight > 0 {
                    lockedAspectRatio = Double(customWidth) / Double(customHeight)
                }
                isAspectRatioLocked = isLocked
            }
        )
    }

    private func restorePickerFocus(_ picker: PickerFocus) {
        focusedPicker = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusedPicker = picker
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            focusedPicker = picker
        }
    }
}
