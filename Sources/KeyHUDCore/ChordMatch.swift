import Foundation

/// Matches a chord the user actually typed against an app's shortcut table.
///
/// This existed only as a private method on `AppDelegate`, so nothing could reach it: the
/// file named `ChordMatchingTests` tested `KeyboardLayout.locate` and `MenuScraper.baseKey`
/// and never once matched a chord. One of its cases was tautological — it asserted that
/// two distinct keys stay distinct, which holds when `locate` returns nil for everything —
/// and would have passed with the layout deleted.
///
/// The matching matters because it is how usage gets credited for apps whose Accessibility
/// layer never reports a menu selection. Electron binds several accelerators per command
/// and only one of them is the menu item, which is why ⌘− was recorded and ⌘+ never was.
enum ChordMatch {

    /// The binding a chord fires, or nil.
    ///
    /// - Parameters:
    ///   - mods: the modifiers actually held, from the event.
    ///   - key: the character the key produces ignoring modifiers — "=" for Shift-"=".
    static func find(mods: Shortcut.Mods, key: String,
                     in sections: [MenuSection]) -> Shortcut? {
        find(mods: mods, key: key, among: sections.flatMap(\.items))
    }

    /// The same match against a bare list. The system text-editing bindings are in no menu
    /// anywhere, so they arrive as a list and must not have to invent a section to be
    /// matched — inventing one meant naming it, in a second place, in a third file.
    static func find(mods: Shortcut.Mods, key: String,
                     among items: [Shortcut]) -> Shortcut? {
        // Match on the physical key, not the printed legend: the menu says "+" for Zoom In
        // while the key that produces it is "=", and an app may name either.
        let pressed = KeyboardLayout.locate(key)?.cap ?? key
        let candidates = items.filter { item in
            guard item.enabled else { return false }
            let target = KeyboardLayout.locate(item.keyLabel)?.cap ?? item.keyLabel
            return target == pressed && accepts(mods, item)
        }
        // Ranked, because array order deciding which shortcut you get credit for is not a
        // rule, it is a coin toss — and an app binding both legends of one key to
        // different commands (⌘= and ⌘+) is exactly where it shows.
        //
        // The legend the user typed wins first: pressing "=" without Shift means the
        // command printed "=", even though the command printed "+" is also reachable from
        // that key. Then the exact modifier match. The concession is the last resort.
        func rank(_ item: Shortcut) -> Int {
            (item.keyLabel == key ? 2 : 0) + (item.mods == mods ? 1 : 0)
        }
        return candidates.max { rank($0) < rank($1) }
    }

    /// What a chord earns credit for, and on whose authority.
    ///
    /// Two tables can claim the same chord and they are not equally trustworthy. A menu
    /// item is a fact about the app that is in front of you. A system text-editing binding
    /// is a fact about AppKit's text system, true only while something that accepts typing
    /// has focus — which cannot be checked here, because this runs inside the event tap
    /// callback on the main run loop and an Accessibility round trip per keystroke is
    /// exactly the kind of slowness that gets a tap disabled. So the case is reported and
    /// the caller confirms it later, off this path.
    enum Credit {
        /// A command from the frontmost app's menu. Countable on the keystroke alone.
        case menu(Shortcut)
        /// A system-wide text-editing binding. Real only if a text element has focus.
        case text(Shortcut)

        var shortcut: Shortcut {
            switch self {
            case .menu(let item), .text(let item): return item
            }
        }
        /// Whether the caller still has to confirm that typing goes somewhere.
        var needsTextFocus: Bool {
            if case .text = self { return true }
            return false
        }
    }

    /// Resolves a chord against both tables, app first.
    ///
    /// The app wins ties on purpose: an app that binds ⌃A to something of its own is doing
    /// that *instead of* the system's binding, not as well as it, and crediting the system
    /// name would record a command the user did not run.
    static func credit(mods: Shortcut.Mods, key: String,
                       menu: [MenuSection], text: [Shortcut]) -> Credit? {
        if let hit = find(mods: mods, key: key, in: menu) { return .menu(hit) }
        if let hit = find(mods: mods, key: key, among: text) { return .text(hit) }
        return nil
    }

    /// Whether the held modifiers can fire this binding.
    ///
    /// Shift is forgiven when the shortcut names a shifted character: typing "+" requires
    /// Shift, and the menu recorded the legend without recording the Shift it takes to
    /// produce it. The concession is one-directional — a binding that genuinely wants
    /// Shift is not fired by a chord without it.
    private static func accepts(_ mods: Shortcut.Mods, _ item: Shortcut) -> Bool {
        if mods == item.mods { return true }
        guard MenuScraper.baseKey(for: item.keyLabel) != nil else { return false }
        return mods == item.mods.union(.shift)
    }
}
