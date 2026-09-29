import AppKit

@MainActor enum AccessibilityRelationshipProbe {
    static func read(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
    static func describe(_ object: NSObject) -> String {
        let keys = ["accessibilityRole", "accessibilitySubrole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityValueDescription", "accessibilityIdentifier"]
        return "class=\(type(of: object)) id=\(ObjectIdentifier(object)) " + keys.map { "\($0)=\(String(describing: read(object, $0)))" }.joined(separator: " ")
    }
    static func report(_ object: NSObject) -> String {
        var seen = Set<ObjectIdentifier>()
        var rows: [String] = []
        func walk(_ node: NSObject, _ path: String, _ depth: Int) {
            guard depth < 8 else { return }
            rows.append("\(path): \(describe(node))")
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            for key in ["accessibilityTitleUIElement", "accessibilityLabelUIElements", "accessibilityLinkedUIElements", "accessibilityServesAsTitleForUIElements", "accessibilityChildren", "accessibilityFocusedUIElement"] {
                if let list = read(node, key) as? [NSObject] {
                    rows.append("\(path).\(key): count=\(list.count)")
                    for (index, child) in list.enumerated() { walk(child, "\(path).\(key)[\(index)]", depth + 1) }
                } else if let child = read(node, key) as? NSObject {
                    walk(child, "\(path).\(key)", depth + 1)
                } else { rows.append("\(path).\(key): nil") }
            }
        }
        walk(object, "root", 0)
        return rows.joined(separator: "\n")
    }
}
