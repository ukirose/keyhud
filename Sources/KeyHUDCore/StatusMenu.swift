import Cocoa

/// The menu-bar item and everything under it.
///
/// This was ~140 lines inside AppDelegate, which also owned permissions, the trigger, the
/// scrape cache and the preview exporter. Menu construction has nothing to do with any of
/// those; separating it leaves the delegate as wiring, and lets the menu be changed
/// without touching the code that decides when a panel appears.
///
/// It talks to the rest of the app through `Actions` rather than by reaching into it, so
/// adding an entry does not mean adding a dependency.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var settings: () -> LearningStore.Settings
        var updateSettings: (LearningStore.Settings) -> Void
        var themeName: () -> String
        var weeklyCounts: () -> [(label: String, count: Int)]
        var trend: () -> String
        var writeDigest: () -> Void
        var openDataFolder: () -> Void
    }

    private var item: NSStatusItem?
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌘"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    /// Rebuilt on open so counts and the coaching list are current, and so the work is
    /// paid for only when the menu is actually used.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = actions.settings()
        menu.removeAllItems()
        menu.addItem(disabled("⌘ / ⌃ / ⌥ を長押しでショートカット表示"))

        menu.addItem(.separator())
        for (title, mode) in [("リスト表示", "list"), ("キーマップ表示 (HHKB US)", "keymap")] {
            menu.addItem(choice(title, mode, checked: s.layoutMode == mode,
                                action: #selector(pickLayout(_:))))
        }

        let sizes = NSMenu()
        for (title, value) in [("小 (1.0)", 1.0), ("中 (1.3)", 1.3), ("大 (1.6)", 1.6), ("特大 (2.0)", 2.0)] {
            sizes.addItem(choice(title, value, checked: abs(s.uiScale - value) < 0.01,
                                 action: #selector(pickScale(_:))))
        }
        menu.addItem(submenu("表示サイズ", sizes))

        menu.addItem(.separator())
        menu.addItem(disabled("テーマ: \(actions.themeName())"))
        menu.addItem(submenu("テーマを選ぶ", themeMenu(current: s.themeSource)))
        menu.addItem(submenu("表示設定", togglesMenu(s)))

        if s.inverseKPI {
            menu.addItem(.separator())
            menu.addItem(disabled("パネル参照回数（減るほど良い）"))
            let weeks = actions.weeklyCounts()
            if weeks.isEmpty {
                menu.addItem(disabled("　まだデータがありません"))
            } else {
                for w in weeks { menu.addItem(disabled("　\(w.label)   \(w.count)")) }
                let t = actions.trend()
                if !t.isEmpty { menu.addItem(disabled("　\(t)")) }
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("今週のダイジェストを書き出す", #selector(writeDigest)))
        menu.addItem(action("データフォルダを開く", #selector(openData)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "KeyHUD を終了",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: - submenus

    /// Ghostty ships hundreds of themes, so they are bucketed by initial letter — one
    /// flat menu of 463 items is a scroll, not a choice.
    private func themeMenu(current: String) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(choice("Ghostty の設定に追従", "ghostty", checked: current == "ghostty",
                           action: #selector(pickTheme(_:))))
        sub.addItem(choice("組み込み (Tokyo Night)", "builtin", checked: current == "builtin",
                           action: #selector(pickTheme(_:))))
        sub.addItem(choice("クラシック Macintosh", "classic", checked: current == "classic",
                           action: #selector(pickTheme(_:))))

        let all = Theme.availableGhosttyThemes()
        guard !all.isEmpty else {
            sub.addItem(.separator())
            sub.addItem(disabled("Ghostty が見つかりません"))
            return sub
        }
        sub.addItem(.separator())
        var buckets: [String: [String]] = [:]
        for name in all { buckets[String(name.prefix(1)).uppercased(), default: []].append(name) }
        for letter in buckets.keys.sorted() {
            let inner = NSMenu()
            for name in buckets[letter]! {
                inner.addItem(choice(name, name, checked: current == name,
                                     action: #selector(pickTheme(_:))))
            }
            sub.addItem(submenu("\(letter)  (\(buckets[letter]!.count))", inner))
        }
        return sub
    }

    private func togglesMenu(_ s: LearningStore.Settings) -> NSMenu {
        let sub = NSMenu()
        for (title, id, on) in [
            ("アプリ別進捗をヘッダーに表示", "perAppProgress", s.perAppProgress),
            ("参照回数の推移を表示", "inverseKPI", s.inverseKPI),
            ("週次ダイジェストを自動生成", "weeklyDigest", s.weeklyDigest),
            ("習得済みを完全に隠す", "hideMastered", s.hideMastered),
        ] {
            sub.addItem(choice(title, id, checked: on, action: #selector(toggleSetting(_:))))
        }
        return sub
    }

    // MARK: - handlers

    @objc private func pickLayout(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        mutate { $0.layoutMode = mode }
    }

    @objc private func pickScale(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        mutate { $0.uiScale = value }
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String else { return }
        mutate { $0.themeSource = source }
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mutate {
            switch id {
            case "perAppProgress":  $0.perAppProgress.toggle()
            case "inverseKPI":      $0.inverseKPI.toggle()
            case "weeklyDigest":    $0.weeklyDigest.toggle()
            case "hideMastered":    $0.hideMastered.toggle()
            default: break
            }
        }
    }

    @objc private func writeDigest() { actions.writeDigest() }
    @objc private func openData() { actions.openDataFolder() }

    private func mutate(_ change: (inout LearningStore.Settings) -> Void) {
        var s = actions.settings()
        change(&s)
        actions.updateSettings(s)
    }

    // MARK: - item builders

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func choice(_ title: String, _ represented: Any, checked: Bool,
                        action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = represented
        mi.state = checked ? .on : .off
        return mi
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }
}
