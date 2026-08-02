import Foundation

/// Everything the panel will draw, resolved once.
///
/// Filtering used to happen in three places — the modifier match in `show`, the
/// enabled/mastered filters in `buildContent`, and a separate count for the modifier bar
/// — and they disagreed. That is not a bug to fix but a shape to remove: the bar could
/// advertise five bindings while the body showed three, and `hasAnything` could pass on a
/// set the body then filtered to nothing, drawing an empty box.
///
/// So the panel takes one of these and renders it verbatim. If a row is here it is drawn,
/// and every count comes from the same pass that produced the rows.
struct PanelContent {
    /// A binding that survived filtering.
    ///
    /// The initialiser is `fileprivate`, so the only way to hold one is to have been
    /// handed it by `resolve`. That is the whole point: a second opinion about what is
    /// visible cannot be written, because there is nowhere else to get the values from.
    ///
    /// This file's header has said since it was written that filtering in more than one
    /// place is "not a bug to fix but a shape to remove". It came back three times anyway
    /// — the modifier bar counting rows `grouped()` then dropped, the board marking caps
    /// for bindings the rows had filtered out, and App.swift recording as consulted things
    /// the panel had deliberately hidden. A comment cannot stop a fourth. A private
    /// initialiser can.
    @dynamicMemberLookup
    struct Visible {
        fileprivate let item: Shortcut
        subscript<T>(dynamicMember keyPath: KeyPath<Shortcut, T>) -> T { item[keyPath: keyPath] }
        /// Getting the binding back out is fine — the gate is on *construction*. Nobody
        /// can decide a binding is visible; they can only be told that one is.
        var shortcut: Shortcut { item }
    }

    struct Combination {
        let mods: Shortcut.Mods
        let count: Int
        fileprivate init(mods: Shortcut.Mods, count: Int) {
            self.mods = mods
            self.count = count
        }
    }

    let appName: String
    let appKey: String
    let mods: Shortcut.Mods

    /// Only `resolve` builds one.
    ///
    /// The `Visible` wrapper stopped anyone deciding a binding was visible, but the
    /// container around it still had an internal memberwise initialiser — so the
    /// "chip says five, body lists three" state this whole type exists to prevent could
    /// still be written in one line by anyone in the module.
    fileprivate init(appName: String, appKey: String, mods: Shortcut.Mods, rows: [Visible],
                     combinations: [Combination], progress: (done: Int, total: Int)?,
                     visibleElsewhere: Set<String>) {
        self.appName = appName
        self.appKey = appKey
        self.mods = mods
        self.rows = rows
        self.combinations = combinations
        self.progress = progress
        self.visibleElsewhere = visibleElsewhere
    }

    /// The bindings for the held combination, already filtered and never empty.
    let rows: [Visible]
    /// Reachable combinations with at least one visible binding, current one included.
    let combinations: [Combination]
    /// Mastery for this app, or nil when the app has never reported a selection and any
    /// fraction would be a guess.
    let progress: (done: Int, total: Int)?

    var isEmpty: Bool { rows.isEmpty }

    /// Nothing to say at all — no bindings under the held keys and none to point at.
    var hasNothingToShow: Bool { rows.isEmpty && combinations.count <= 1 }

    /// What was drawn, for whoever needs to know what the user was shown. Derived here so
    /// no caller has to reconstruct it, which is how it went wrong before.
    var shownPaths: [[String]] { rows.map(\.path) }

    /// Columns left to right by how much attention each still wants.
    ///
    /// The leftmost position — the first thing read — belongs to what still needs work, so
    /// the finished ones go last and dim. They used to be dropped entirely, which broke the
    /// one property this type exists to guarantee: they were still counted in the modifier
    /// bar, so a chip read "⌘ 20" above 17 rows. An app where everything had graduated drew
    /// a header, a chip claiming twenty bindings, and an empty rectangle.
    ///
    /// Dropping them was also wrong on its own terms. A mastered shortcut still answers
    /// "what is ⌘K here?", and a panel that knows the answer and withholds it is not less
    /// noisy, it is less useful. Dim says "you know this one" without spending attention.
    enum Bucket: Int, CaseIterable {
        case learning, unused, mastered
    }

    struct Group {
        let bucket: Bucket
        let items: [Visible]
        fileprivate init(bucket: Bucket, items: [Visible]) {
            self.bucket = bucket
            self.items = items
        }

        /// Splits into columns of at most `rows`, keeping the bucket. The panel does this
        /// when a column would run off the bottom of the screen; it used to build the
        /// `Group`s itself, which meant the memberwise initialiser had to stay internal
        /// and the counting invariant could be sidestepped by anyone constructing one.
        func chunked(into rows: Int) -> [Group] {
            guard rows > 0, items.count > rows else { return [self] }
            return stride(from: 0, to: items.count, by: rows).map {
                Group(bucket: bucket, items: Array(items[$0..<min($0 + rows, items.count)]))
            }
        }
    }

    /// Splits the visible bindings into columns by how well they are known.
    ///
    /// Ordering inside a column is deliberately conservative. A stable position is itself
    /// a learning aid — once ⌘S is always in the same place you learn where to look — so
    /// re-sorting by frequency would destroy the very cue the panel is trying to build.
    /// Two columns earn an exception, because in them the order carries information the
    /// menu order cannot: what you reach for with the mouse most often is what is most
    /// worth learning, and what is closest to graduating is worth finishing.
    func grouped(learning: LearningStore?) -> [Group] {
        var buckets: [Bucket: [Visible]] = [:]
        for item in rows {
            let bucket: Bucket
            switch learning?.emphasis(app: appKey, path: item.path) ?? .none {
            case .learning:   bucket = .learning
            case .hallOfFame: bucket = .mastered
            case .none:       bucket = .unused
            }
            buckets[bucket, default: []].append(item)
        }

        return Bucket.allCases.compactMap { bucket in
            guard var items = buckets[bucket], !items.isEmpty else { return nil }
            switch bucket {
            case .learning:
                items.sort {
                    (learning?.score(app: appKey, path: $0.path) ?? 0)
                        > (learning?.score(app: appKey, path: $1.path) ?? 0)
                }
            case .unused, .mastered:
                break   // menu order — stable position is the point
            }
            return Group(bucket: bucket, items: items)
        }
    }

    /// - Parameter visible: the same predicate the body uses, applied before anything is
    ///   counted, so the bar and the rows can never disagree.
    static func resolve(appName: String, appKey: String, mods: Shortcut.Mods,
                        sections menuSections: [MenuSection], learning: LearningStore?,
                        hideDisabled: Bool, hideMastered: Bool,
                        textBindings: [Shortcut] = [],
                        canTypeFunctionModifier: Bool = true,
                        canTypeFunctionKeys: Bool = true) -> PanelContent {
        // The system text-editing layer is folded in as another source. It is in no menu
        // bar anywhere, which is why holding Control used to produce an empty panel on a
        // keyboard whose whole layout exists to make Control convenient.
        //
        // Handed in, not fetched. This used to ask the Accessibility API what has focus
        // and then reach for a global backed by two plists on disk — an IPC round trip and
        // a file read, inside the function that decides what the panel says. Harmless at
        // once per keypress; not harmless now that the panel resolves every combination up
        // front to size itself. Taking them as a parameter also leaves this file with no
        // I/O of any kind, which is what lets its whole decision be tested.
        var sections = menuSections
        if !textBindings.isEmpty {
            sections.append(MenuSection(name: "テキスト編集", items: textBindings))
        }
        func visible(_ item: Shortcut) -> Bool {
            // A binding needing fn cannot be typed on a keyboard that resolves fn in its
            // own firmware — 絵文字と記号 and the whole macOS 15 window-tiling block are
            // listed by every app and are, on this hardware, unpressable. Showing them is
            // the same noise as showing text-editing keys in a file list.
            if !canTypeFunctionModifier && item.mods.contains(.function) { return false }
            // And a binding on F1–F12 cannot be typed when macOS is spending those keys
            // on brightness, Mission Control and volume. A laptop escapes that by holding
            // fn; this board cannot, because its fn never leaves the keyboard. So the
            // seventeen F-key bindings an IDE offers are not merely awkward here, they
            // are unreachable, and one of them opens System Settings instead of firing.
            if !canTypeFunctionKeys && item.needsStandardFunctionKeys { return false }
            if hideDisabled && !item.enabled { return false }
            if hideMastered, let learning,
               case .hallOfFame = learning.emphasis(app: appKey, path: item.path) { return false }
            return true
        }

        var counts: [Int: Int] = [:]
        var kept: [Visible] = []
        var elsewhere: Set<String> = []
        for section in sections {
            for item in section.items where visible(item) {
                // Only combinations a hold can produce. ⇧-alone and modifier-less
                // bindings are unreachable, so advertising them promises a view the user
                // can never open.
                guard item.mods.isReachable else { continue }
                counts[item.mods.rawValue, default: 0] += 1
                if item.mods == mods {
                    kept.append(Visible(item: item))
                } else if let cap = KeyboardLayout.locate(item.keyLabel)?.cap {
                    // No second `enabled` test here. It ignored `hideDisabled`, so with
                    // that off a disabled binding was drawn as a row on its own page while
                    // its cap stayed unmarked — the same two-opinions bug, one line long.
                    elsewhere.insert(cap)
                }
            }
        }

        // The held combination is always listed, even at zero. Holding ⌃ finds nothing in
        // most apps — measured across twelve, not one has a ⌃-only or ⌥-only binding —
        // and the panel used to withdraw, which read as "⌃ does not work" rather than as
        // "⌃ is used in combination here". Showing "⌃ 0" beside "⌃ ⌘ 9" answers it.
        if mods.isReachable { counts[mods.rawValue] = counts[mods.rawValue] ?? 0 }

        let combinations = counts.keys.map { Shortcut.Mods(rawValue: $0) }
            .sorted { a, b in
                let (ca, cb) = (a.rawValue.nonzeroBitCount, b.rawValue.nonzeroBitCount)
                return ca == cb ? a.rawValue < b.rawValue : ca < cb
            }
            .map { Combination(mods: $0, count: counts[$0.rawValue]!) }

        return PanelContent(appName: appName, appKey: appKey, mods: mods,
                            rows: kept, combinations: combinations,
                            progress: learning?.progress(app: appKey),
                            visibleElsewhere: elsewhere)
    }

    /// Every binding that survived filtering, whatever combination it needs.
    ///
    /// The board marks caps that carry a binding under some *other* combination, and it
    /// used to build that set with its own filter — enabled, reachable, not the held
    /// combination. That is not the predicate the rows use. Bindings dropped for needing
    /// fn, or for sitting on an F-key macOS has taken, vanished from every chip and every
    /// row and still lit their cap: measured over the captured corpus, four to eight ghost
    /// caps per app, on every one of the thirteen. The user presses every combination
    /// looking for something that was deliberately hidden.
    ///
    /// So the resolve pass publishes what it kept, and the board is not allowed its own
    /// opinion about what exists.
    let visibleElsewhere: Set<String>
}
