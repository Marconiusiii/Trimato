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

struct ProjectCreationView: View {
    @ObservedObject var controller: ProjectController
    let finish: () -> Void

    @State private var name: String
    @State private var mode: ProjectFormatMode
    @State private var width: Int
    @State private var height: Int
    @State private var frameRate: Double
    @State private var usesTargetDuration: Bool
    @State private var targetSeconds: Double
    @State private var validationError: String?
    @AccessibilityFocusState private var headingFocused: Bool
    @AccessibilityFocusState private var validationErrorFocused: Bool

    init(controller: ProjectController, finish: @escaping () -> Void) {
        self.controller = controller
        self.finish = finish
        let project = controller.project
        _name = State(initialValue: project.name)
        _mode = State(initialValue: project.format.mode)
        _width = State(initialValue: project.format.width ?? 1_920)
        _height = State(initialValue: project.format.height ?? 1_080)
        _frameRate = State(initialValue: project.format.frameRate ?? 30)
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
                    TextField("Width", value: $width, format: .number)
                    TextField("Height", value: $height, format: .number)
                    TextField("Frame Rate", value: $frameRate, format: .number)
                    Text("Use even dimensions from 2 through 8,192 pixels and a frame rate from 1 through 240 fps. Fractional frame rates are allowed.")
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
                           width: width,
                           height: height,
                           frameRate: frameRate
                        ) {
                        validationError = message
                        DispatchQueue.main.async { validationErrorFocused = true }
                        return
                    }
                    validationError = nil
                    let format = ProjectFormat(
                        mode: mode,
                        width: mode == .custom ? width : nil,
                        height: mode == .custom ? height : nil,
                        frameRate: mode == .custom ? frameRate : nil
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
}
