import Foundation

nonisolated enum TextTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case centerTitle, titleAndSubtitle, lowerCenter, lowerLeft, lowerRight, nameAndRole, caption, subtitle
    var id: Self { self }
    var title: String {
        switch self {
        case .centerTitle: "Center Title"
        case .titleAndSubtitle: "Title and Subtitle"
        case .lowerCenter: "Lower Third, Center"
        case .lowerLeft: "Lower Third, Left"
        case .lowerRight: "Lower Third, Right"
        case .nameAndRole: "Name and Role"
        case .caption: "Caption"
        case .subtitle: "Subtitle"
        }
    }
    var hasSecondaryText: Bool { self == .titleAndSubtitle || self == .nameAndRole }
    var textLabel: String { self == .nameAndRole ? "Name" : (self == .titleAndSubtitle ? "Title" : "Text") }
    var secondaryLabel: String { self == .nameAndRole ? "Role" : "Subtitle" }
}

nonisolated enum TextFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case sans, rounded, serif, monospaced
    var id: Self { self }
    var title: String {
        switch self {
        case .sans: "System Sans"
        case .rounded: "Rounded Sans"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }
}

nonisolated enum TextFontWeight: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular, medium, semibold, bold
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

nonisolated enum TextAlignmentChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

nonisolated enum TextPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight
    var id: Self { self }
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .centerLeft: "Center Left"
        case .center: "Center"
        case .centerRight: "Center Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

nonisolated enum TextBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, transparent
    var id: Self { self }
    var title: String { self == .black ? "Black" : "Transparent" }
}

nonisolated enum TextColorChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case white, black, red, green, blue, yellow, cyan, magenta, gray, custom
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var hex: String {
        switch self {
        case .white: "FFFFFF"
        case .black: "000000"
        case .red: "FF0000"
        case .green: "008000"
        case .blue: "0000FF"
        case .yellow: "FFFF00"
        case .cyan: "00FFFF"
        case .magenta: "FF00FF"
        case .gray: "808080"
        case .custom: "FFFFFF"
        }
    }
}

nonisolated struct TextGeneratorColor: Codable, Hashable, Sendable {
    var choice: TextColorChoice = .white
    var customHex = "FFFFFF"
    var hex: String { choice == .custom ? customHex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "") : choice.hex }
    var rgb: (Double, Double, Double)? {
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
}

nonisolated struct TextGeneratorSettings: Codable, Hashable, Sendable {
    var template: TextTemplate = .centerTitle
    var text = ""
    var secondaryText = ""
    var font: TextFontFamily = .sans
    var weight: TextFontWeight = .semibold
    // Relative sizing makes the saved style scale with the project frame.
    var sizePercent = 6.0
    var alignment: TextAlignmentChoice = .center
    var position: TextPosition = .center
    var color = TextGeneratorColor()
    var background: TextBackground = .black
    var outlineEnabled = false
    var outlineColor = TextGeneratorColor(choice: .black)
    var shadowEnabled = false
    var panelEnabled = false
    var panelColor = TextGeneratorColor(choice: .black)
    var panelOpacity = 70.0
    var safeMargin = 5.0
    var maximumWidth = 90.0
    var horizontalOffset = 0.0
    var verticalOffset = 0.0
    var lineSpacing = 15.0

    mutating func apply(_ template: TextTemplate) {
        // Reset style only. Keep both text fields even when the new preset hides the second.
        let savedText = text, savedSecondary = secondaryText
        self = Self()
        self.template = template
        text = savedText
        secondaryText = savedSecondary
        switch template {
        case .centerTitle, .titleAndSubtitle: break
        case .lowerCenter, .lowerLeft, .lowerRight, .nameAndRole:
            background = .transparent
            sizePercent = 4.5
            position = .bottomCenter
            outlineEnabled = true
            if template == .lowerLeft || template == .nameAndRole { position = .bottomLeft; alignment = .left }
            if template == .lowerRight { position = .bottomRight; alignment = .right }
        case .caption, .subtitle:
            background = .transparent
            sizePercent = 4.2
            position = .bottomCenter
            maximumWidth = 85
            weight = .medium
            panelEnabled = template == .caption
            outlineEnabled = template == .subtitle
        }
    }

    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaSourceError.unreadable("Enter text for the generator.")
        }
        guard text.utf16.count + secondaryText.utf16.count <= 10_000 else {
            throw MediaSourceError.unreadable("Use no more than 10,000 characters in one text generator.")
        }
        let values: [(Double, ClosedRange<Double>, String)] = [
            (sizePercent, 1...25, "Text size"), (safeMargin, 0...20, "Safe margin"),
            (maximumWidth, 10...100, "Maximum text width"), (panelOpacity, 0...100, "Panel opacity"),
            (horizontalOffset, -50...50, "Horizontal offset"), (verticalOffset, -50...50, "Vertical offset"),
            (lineSpacing, 0...100, "Line spacing")
        ]
        for (value, range, name) in values where !value.isFinite || !range.contains(value) {
            throw MediaSourceError.unreadable("\(name) must be between \(range.lowerBound) and \(range.upperBound) percent.")
        }
        for ink in [color, outlineEnabled ? outlineColor : color, panelEnabled ? panelColor : color] {
            guard ink.rgb != nil else { throw MediaSourceError.unreadable("Enter a six-digit hexadecimal color, such as FFFFFF for white.") }
        }
    }
}
