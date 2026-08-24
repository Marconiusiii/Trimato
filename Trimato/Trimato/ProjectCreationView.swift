import SwiftUI

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
    @AccessibilityFocusState private var headingFocused: Bool

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
                }

                Toggle("Use Target Duration", isOn: $usesTargetDuration)
                if usesTargetDuration {
                    TextField("Target Duration in Seconds", value: $targetSeconds, format: .number)
                }
            }

            HStack {
                Spacer()
                Button("Save Project Settings") {
                    let format = ProjectFormat(
                        mode: mode,
                        width: mode == .custom ? max(width, 1) : nil,
                        height: mode == .custom ? max(height, 1) : nil,
                        frameRate: mode == .custom ? max(frameRate, 1) : nil
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
