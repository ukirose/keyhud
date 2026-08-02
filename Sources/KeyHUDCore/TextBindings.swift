import Cocoa

/// macOS's system-wide text editing keys — the readline/Emacs layer.
///
/// Every source the panel had until now came from an application's menu bar, and these
/// are in no menu anywhere: ^A, ^E, ^K, ^Y and the rest are implemented by AppKit's text
/// system and work in every text field on the machine. That is why holding Control
/// produced an empty panel — not because Control does nothing, but because the panel was
/// only looking where Control is never listed.
///
/// This matters more on an HHKB than on a laptop keyboard. The board puts Control where
/// Caps Lock sits precisely so these can be typed without moving your hand, which is the
/// Unix arrangement the keyboard was designed around; a shortcut viewer that cannot see
/// them is blind to the half of the keyboard this hardware exists to serve.
///
/// Read from AppKit's StandardKeyBinding.dict, plus the user's own overrides in
/// ~/Library/KeyBindings/DefaultKeyBinding.dict when present — so a customised board
/// reports its own bindings rather than Apple's defaults.
enum TextBindings {
    private static let systemDict = URL(fileURLWithPath:
        "/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict")
    private static var userDict: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/KeyBindings/DefaultKeyBinding.dict")
    }

    /// Modifier prefixes used in the dictionaries' key syntax.
    private static let prefixes: [(Character, Shortcut.Mods)] = [
        ("^", .control), ("~", .option), ("$", .shift), ("@", .command),
    ]

    /// A readable name for each selector. The raw selector is an implementation detail
    /// ("moveToBeginningOfParagraph:"); what belongs on the panel is what it does.
    private static let names: [String: String] = [
        "moveToBeginningOfParagraph:": "行頭へ",
        "moveToEndOfParagraph:": "行末へ",
        "moveToBeginningOfDocument:": "先頭へ",
        "moveToEndOfDocument:": "末尾へ",
        "moveForward:": "1文字進む",
        "moveBackward:": "1文字戻る",
        "moveUp:": "1行上",
        "moveDown:": "1行下",
        "moveWordForward:": "1語進む",
        "moveWordBackward:": "1語戻る",
        "deleteForward:": "前を削除",
        "deleteBackward:": "後ろを削除",
        "deleteToEndOfParagraph:": "行末まで削除",
        "deleteWordBackward:": "1語削除",
        "yank:": "削除したものを貼る",
        "transpose:": "前後を入れ替え",
        "centerSelectionInVisibleArea:": "画面中央へ",
        "insertNewline:": "改行",
        "insertLineBreak:": "改行を挿入",
        "insertTab:": "タブ",
        "cancelOperation:": "取り消し",
        "complete:": "補完",
        "pageDown:": "1画面下",
        "pageUp:": "1画面上",
        "scrollPageDown:": "1画面スクロール下",
        "scrollPageUp:": "1画面スクロール上",
        "selectAll:": "すべて選択",
        "selectLine:": "行を選択",
        "selectWord:": "語を選択",
    ]

    /// Parsed once — the dictionaries do not change while the app runs.
    static let all: [Shortcut] = load()

    /// Whether the thing with focus right now actually accepts these.
    ///
    /// ^A moves to the beginning of a line inside a text field and does nothing at all in
    /// a file list, so listing it unconditionally is noise on exactly the modifier that
    /// had too little to show. Asked of the focused element rather than assumed.
    /// The roles this layer is offered in. Named so a test can pin the list: what the gate
    /// *answers* needs a focused element and an Accessibility-trusted process, neither of
    /// which a test has, but which roles count is the decision that matters.
    static let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    static func applyToFocusedElement() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String,
           textRoles.contains(role) { return true }

        // Terminals and editors often expose a custom role but still carry a text
        // selection; that is the more reliable signal of "typing happens here".
        var selection: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                             &selection) == .success
    }

    private static func load() -> [Shortcut] {
        var merged: [String: Any] = read(systemDict)
        // A user file replaces individual entries rather than the whole set, which is how
        // AppKit itself merges them.
        for (k, v) in read(userDict) { merged[k] = v }

        return merged.compactMap { raw, action -> Shortcut? in
            guard let (mods, key) = parse(raw) else { return nil }
            // Only what a hold can reach, and only single keys — the dictionaries also
            // contain multi-stroke sequences, which this panel has no way to present.
            guard mods.isReachable, key.count == 1 else { return nil }
            guard let selector = firstSelector(action), let name = names[selector] else { return nil }
            return Shortcut(path: ["テキスト編集", name], mods: mods, keyLabel: key.uppercased(),
                            source: .char, element: nil, enabled: true)
        }
        .sorted { $0.keyLabel < $1.keyLabel }
    }

    private static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    private static func firstSelector(_ action: Any) -> String? {
        if let s = action as? String { return s }
        if let list = action as? [String] { return list.first }
        return nil
    }

    /// "^a" -> (control, "a"). Returns nil for anything that is not a single chord.
    private static func parse(_ raw: String) -> (Shortcut.Mods, String)? {
        var mods = Shortcut.Mods()
        var rest = Substring(raw)
        while let first = rest.first, let match = prefixes.first(where: { $0.0 == first }) {
            mods.insert(match.1)
            rest = rest.dropFirst()
        }
        guard rest.count == 1, let ch = rest.first,
              ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol else { return nil }
        return (mods, String(ch))
    }
}
