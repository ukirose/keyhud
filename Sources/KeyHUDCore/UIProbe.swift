import Cocoa
import ApplicationServices

/// Measures the ceiling on "watch the mouse and suggest a shortcut".
///
/// The idea is to notice what is being done by clicking and offer the keyboard equivalent.
/// Its upper bound is not click detection — that part is easy — but the *overlap*: a click
/// only becomes a suggestion when the thing clicked also exists as a menu item that has a
/// key equivalent. If a window's toolbars and sidebars expose thirty controls and two of
/// them are also shortcut-bearing menu commands, the feature has two suggestions to make
/// in that app, no matter how well the mouse is observed.
///
/// So this measures the overlap directly, and does it without watching anything: it walks
/// the accessibility tree of a window that is already on screen and intersects the control
/// names with the menu. A snapshot of the interface, not a record of behaviour. No clicks,
/// no coordinates, no keystrokes, and no element *values* — only the names of controls,
/// which are the same command names the menu already publishes.
enum UIProbe {
    struct Result {
        let app: String
        let elements: Int
        let controls: Int
        let named: Int
        /// Control names that are also a menu command with a key equivalent — the ones a
        /// click on them could be turned into a suggestion.
        let matched: [(name: String, chord: String)]
        /// Named controls with no shortcut-bearing menu counterpart. These are the names
        /// of buttons and other affordances, not rows or text, so they are labels the
        /// interface publishes rather than anything the user wrote.
        let unmatchedNames: [String]
        var unmatched: Int { named - matched.count }
    }

    /// Roles that represent something a person clicks to run a command. Text, images,
    /// groups and scroll areas are skipped — clicking those is navigation, not a command.
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXMenuButtonRole, kAXToolbarRole, kAXTabGroupRole,
        "AXToolbarButton", "AXDisclosureTriangle", "AXSegmentedControl",
    ]

    private static let maxElements = 6000
    private static let maxDepth = 30

    static func probe(pid: pid_t, name: String) -> Result {
        let shortcuts = MenuScraper.scrape(pid: pid).flatMap(\.items)
        var byName: [String: Shortcut] = [:]
        for item in shortcuts where item.mods.isReachable {
            byName[normalise(item.title)] = item
        }

        var elements = 0, controls = 0
        var names: [String] = []
        var seen = Set<CFHashCode>()

        func walk(_ element: AXUIElement, depth: Int) {
            guard elements < maxElements, depth < maxDepth else { return }
            guard seen.insert(CFHash(element)).inserted else { return }
            elements += 1

            if let role = string(element, kAXRoleAttribute), controlRoles.contains(role) {
                controls += 1
                // Title first, then the accessibility description — a toolbar button often
                // has only the latter. Never AXValue: that is the content, not the name.
                if let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute),
                   !title.isEmpty {
                    names.append(title)
                }
            }
            guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }

        let app = AXUIElementCreateApplication(pid)
        // Chromium and Electron build their accessibility tree only once an assistive
        // technology asks for it. Without this, VS Code and Antigravity return no elements
        // at all and the measurement below would be of their laziness, not of their UI.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Windows only. The menu bar is deliberately excluded: menu clicks are already
        // detected, and counting them here would flatter the result with the one signal
        // that does not need this feature.
        if let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows { walk(window, depth: 0) }
        }

        var matched: [(String, String)] = []
        var used = Set<String>()
        for raw in names {
            let key = normalise(raw)
            guard let hit = byName[key], used.insert(key).inserted else { continue }
            matched.append((raw, hit.keys))
        }
        let matchedNames = Set(matched.map { normalise($0.0) })
        return Result(app: name, elements: elements, controls: controls,
                      named: names.count, matched: matched,
                      unmatchedNames: Array(Set(names.filter { !matchedNames.contains(normalise($0)) })).sorted())
    }

    /// "共有…" and "共有" are the same command. Ellipses, whitespace and case are noise.
    static func normalise(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }
}
