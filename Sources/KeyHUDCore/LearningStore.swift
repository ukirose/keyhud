import Foundation

/// Testing seam. "graduates after 5 unaided presses spanning 3 distinct days" and
/// "goes rusty after 30–90 days" are otherwise unverifiable without waiting months.
/// KEYHUD_FAKE_NOW takes an ISO8601 date; everything time-dependent reads through here.
enum Clock {
    private static let fake: Date? = ProcessInfo.processInfo.environment["KEYHUD_FAKE_NOW"]
        .flatMap { ISO8601DateFormatter().date(from: $0) }
    /// Settable so a test can walk a record through weeks of history in one process.
    /// KEYHUD_FAKE_NOW is read once at load and cannot vary within a run, which is fine
    /// for driving the app by hand but useless for asserting on a state machine.
    static var override: Date?
    static var isFake: Bool { override != nil || fake != nil }
    static func now() -> Date { override ?? fake ?? Date() }
}

/// Where the JSON/JSONL live. Overridable so verification runs cannot touch real
/// history — the store's entire value is accumulated data, and a test that clobbers it
/// costs more than it proves.
/// The default was `~/Developer/keyhud/data` — this checkout's own folder, which exists on
/// exactly one machine. Anywhere else the app wrote its history into a directory that was
/// not there, so a fresh clone could run and record nothing. Application Support is where a
/// macOS app's own data belongs; the checkout keeps only fixtures and generated previews.
enum DataDir {
    static let url: URL = {
        if let override = ProcessInfo.processInfo.environment["KEYHUD_DATA_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("KeyHUD")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["KEYHUD_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("keyhud: " + message() + "\n").utf8))
}

/// Per-shortcut learning state, persisted locally.
///
/// The model is built around one distinction the app already measures: a shortcut press
/// made UNAIDED (free recall) versus one made within seconds of looking it up on the
/// panel (assisted). Only unaided recall earns progress — the panel must never be the
/// thing being rewarded, or the tool starts optimising for its own use.
///
/// Ranking by raw use-frequency is deliberately absent: the three prior tools that
/// emphasised what you already use all died at 0–2 stars, because the shortcuts you use
/// most are the ones you never need shown. Here frequency only ever *removes* emphasis.
///
/// Graduation is not permanent. An item you mastered and then stopped using goes `rusty`
/// and returns to normal visibility — otherwise the panel would hide precisely the
/// entries you have started to forget, which is when you need them most. How long that
/// takes scales with how well it was drilled.
final class LearningStore {
    enum Emphasis {
        /// 0…1 — the score, which is also what the gauge draws.
        case learning(Double)
        case hallOfFame
        case none
    }

    struct Settings: Codable {
        var perAppProgress = true      // M2
        var inverseKPI = true          // M4
        var weeklyDigest = true        // M5
        var hideMastered = false       // M6 — off by default; dimming is the softer default
        /// "classic" is the Macintosh palette this app is drawn for, "ghostty" follows
        /// ~/.config/ghostty/config, "builtin" is Tokyo Night, and anything else names one
        /// of Ghostty's installed themes.
        ///
        /// The default used to be "ghostty", which meant a fresh install looked like
        /// whatever terminal the machine happened to have — and nothing at all like the
        /// screenshots. The panel's shape was designed around this palette; following
        /// something else is a choice, not a starting point.
        var themeSource = "classic"
        /// "list" or "keymap".
        var layoutMode = "list"
        /// Multiplies every font and key size. Default is deliberately above 1: the first
        /// build drew 9pt legends in a thin mono face on a dark background, which is not
        /// readable at a glance — and a glance is the entire interaction.
        var uiScale = 1.3
        /// Show the chain of unaided presses as pips next to a row being learned.

        init() {}

        /// Optional-decoded for the same reason `Record` is: a settings block written
        /// before a new toggle existed must load with that toggle defaulted, not throw.
        /// A throw here would fail the whole StoreFile decode and send a perfectly good
        /// history to the .bak path.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            perAppProgress = try c.decodeIfPresent(Bool.self, forKey: .perAppProgress) ?? true
            inverseKPI = try c.decodeIfPresent(Bool.self, forKey: .inverseKPI) ?? true
            weeklyDigest = try c.decodeIfPresent(Bool.self, forKey: .weeklyDigest) ?? true
            hideMastered = try c.decodeIfPresent(Bool.self, forKey: .hideMastered) ?? false
            themeSource = try c.decodeIfPresent(String.self, forKey: .themeSource) ?? "classic"
            layoutMode = try c.decodeIfPresent(String.self, forKey: .layoutMode) ?? "list"
            uiScale = try c.decodeIfPresent(Double.self, forKey: .uiScale) ?? 1.3
        }
    }

    // MARK: - persisted shapes

    /// A single score, 0…100, instead of a chain plus a distinct-day count plus a rust
    /// threshold plus a graduation predicate.
    ///
    /// The old chain was five steps, so one press moved the gauge a fifth of the way and
    /// the fifth press pinned it at full with nowhere further to go — a progress bar that
    /// is either coarse or finished is not a progress bar. A score earns slowly, is capped
    /// per day so it cannot be farmed in one sitting, decays with disuse, and takes a real
    /// but survivable hit when the mouse wins. Rust is no longer a separate state: an item
    /// left alone simply slides back down the same bar it climbed.
    private struct Record: Codable {
        /// The shape of this record, and the reason it exists.
        ///
        /// The model was rewritten from a five-step chain to a score, and `version` on the
        /// *file* was not bumped because the file's shape had not changed. Only the
        /// records' had. Every field being `decodeIfPresent`, twenty of this machine's real
        /// records loaded as valid, scored zero, and were written straight back out that
        /// way: fifty-one unaided presses of one shortcut now read as untouched.
        ///
        /// So the record carries its own version and decoding *requires* it. Tolerant
        /// decoding is right for adding a field and wrong for changing what the fields
        /// mean, and nothing in the old design could tell those apart. A record that does
        /// not announce its shape is now routed to repair instead of being believed.
        static let currentVersion = 3
        var v = currentVersion
        var score: Double = 0
        /// When `score` was last written — decay is applied from here, lazily, because
        /// nothing can run while the app is idle.
        var scoredAt: Date?
        var gainedOn = ""            // day-stamp of the last gain
        var gainedThatDay: Double = 0
        var kbUses = 0
        var mousePicks = 0
        /// True for a record whose score was never written by the score model. Their
        /// counts and dates are intact; only the score is missing, and it cannot be
        /// reconstructed from the record alone — replaying the usage log can, which is a
        /// deliberate step and not something to do behind the user's back.
        /// Raised at load for a record whose score predates the score model, and lowered
        /// only by an actual repair.
        ///
        /// It has to be stored rather than derived. Deriving it from `v < 3 && kbUses > 0
        /// && score == 0` meant the flag went out the moment the record earned a point —
        /// so the count never converged and never reached zero, and a record that decayed
        /// back to zero started counting again. A repair is an event, not a shape.
        var needsScoreRepair = false
        var lastKbUse: Date?
        /// Written, never read. Its two readers were the orange to-learn state and the
        /// "stop coaching" list, both removed. Kept because it is accumulated history in a
        /// versioned record and dropping the field would quietly discard it on the next
        /// save for no gain; `mousePicks` next to it is still read. Say so here rather than
        /// leave a reader to be looked for.
        var lastMousePick: Date?
        var lastAssisted: Date?
        var everUnaided = false
        var hallOfFameLogged = false

        init() {}

        /// Optional-decoded so a file written by any earlier version loads with defaults
        /// rather than throwing — a throw here would send real history to the .bak path.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Absent means the record predates the score model. Not a throw: throwing here
            // would route a whole file of real history to the preserve-and-start-empty
            // path. It is enough that the difference is *visible*, because the failure was
            // never a decode error — it was that nothing could tell an old shape from a
            // new one, so twenty records were read as legitimately scoring zero.
            v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 0
            score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
            scoredAt = try c.decodeIfPresent(Date.self, forKey: .scoredAt)
            gainedOn = try c.decodeIfPresent(String.self, forKey: .gainedOn) ?? ""
            gainedThatDay = try c.decodeIfPresent(Double.self, forKey: .gainedThatDay) ?? 0
            kbUses = try c.decodeIfPresent(Int.self, forKey: .kbUses) ?? 0
            mousePicks = try c.decodeIfPresent(Int.self, forKey: .mousePicks) ?? 0
            lastKbUse = try c.decodeIfPresent(Date.self, forKey: .lastKbUse)
            lastMousePick = try c.decodeIfPresent(Date.self, forKey: .lastMousePick)
            lastAssisted = try c.decodeIfPresent(Date.self, forKey: .lastAssisted)
            needsScoreRepair = try c.decodeIfPresent(Bool.self, forKey: .needsScoreRepair) ?? false
            everUnaided = try c.decodeIfPresent(Bool.self, forKey: .everUnaided) ?? false
            hallOfFameLogged = try c.decodeIfPresent(Bool.self, forKey: .hallOfFameLogged) ?? false
        }
    }

    private struct AppRecord: Codable {
        /// M2 denominator: every shortcut-bearing item ever seen enabled in this app.
        var observed: Set<String> = []
        /// M2 honesty gate. Apps that never emit kAXMenuItemSelected (terminal apps and
        /// some Electron hosts) would otherwise show a permanent, dishonest "0/143".
        var selectionEventsSeen = 0
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            observed = try c.decodeIfPresent(Set<String>.self, forKey: .observed) ?? []
            selectionEventsSeen = try c.decodeIfPresent(Int.self, forKey: .selectionEventsSeen) ?? 0
        }
    }

    private struct StoreFile: Codable {
        var version = 2
        var records: [String: Record] = [:]
        var apps: [String: AppRecord] = [:]
        var settings = Settings()
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `version` is required, and that is load-bearing. Every other field is
            // optional-decoded, so without this a v1 file — whose top level is a bare
            // dictionary of records — decodes "successfully" as an EMPTY v2 store,
            // never reaches the migration branch, and gets overwritten on the next
            // save. Tolerant decoding reintroduced the exact silent data loss the
            // rewrite was meant to remove; demanding this one key is what stops it.
            version = try c.decode(Int.self, forKey: .version)
            records = try c.decodeIfPresent([String: Record].self, forKey: .records) ?? [:]
            apps = try c.decodeIfPresent([String: AppRecord].self, forKey: .apps) ?? [:]
            settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        }
    }

    // MARK: - tunables

    /// One unaided press. Reaching 100 takes roughly a week of using something twice a
    /// day — long enough to mean something, short enough to see the bar move.
    private let gainPerRecall = 8.0
    /// Per-day ceiling on gains. Pressing the same key twenty times in one sitting is
    /// repetition, not recall on twenty occasions, and the old model needed a separate
    /// "three distinct days" rule to say so.
    private let dailyGainCap = 16.0
    /// Reaching for the mouse instead. A setback rather than a wipe: losing everything to
    /// one slip made the number feel arbitrary.
    private let mousePenalty = 25.0
    /// Points shed per day of disuse, after a few days' grace. This is rust, made
    /// continuous — a hall-of-famer left alone for months slides back into practice.
    private let decayPerDay = 1.0
    private let decayGraceDays = 3.0
    private let hallOfFameScore = 100.0
    private let staleDays = 30.0

    // MARK: - state

    private var file = StoreFile()
    private let url: URL
    private let eventsURL: URL
    private var savePending = false
    /// Set when the store could not be read *and* could not be set aside. Saving is then
    /// disabled for the run, because the alternative is writing an empty store over a file
    /// that may still be recoverable by hand.
    private var readOnly = false

    private static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // Both required. A DateFormatter inherits the user's locale and calendar, and on
        // a Japanese-configured Mac set to the Japanese calendar "yyyy" yields era years
        // ("0008-08-02") — which would silently break distinct-day counting, and change
        // meaning if the setting is ever switched.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current   // a "practice day" is the user's local day, not UTC
        return f
    }()

    var settings: Settings {
        get { file.settings }
        set { file.settings = newValue; scheduleSave() }
    }

    /// The directory is a parameter so tests get a throwaway one; the store's whole value
    /// is accumulated history, and a test that clobbers the real file costs more than it
    /// proves.
    init(directory: URL = DataDir.url) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("learning.json")
        eventsURL = dir.appendingPathComponent("events.jsonl")
        load()
    }

    /// Never destroys an unreadable file. The previous loader used `try?` and fell back
    /// to an empty dictionary, so one decode failure silently became total data loss on
    /// the next debounced save — the worst possible failure mode for a store whose whole
    /// value is accumulated history.
    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(StoreFile.self, from: data), decoded.version >= 2 {
            file = decoded
            let stale = stampPreScoreRecords()
            debugLog("loaded v\(decoded.version): \(decoded.records.count) records, "
                     + "\(decoded.apps.count) apps"
                     + (stale > 0 ? ", \(stale) need score repair "
                        + "(counts intact, score lost — run tools/replay-scores.py)" : ""))
            return
        }
        // Strict decoding failed. Before treating the file as unreadable, try again with
        // the record version relaxed: that is what a store written before records carried
        // one looks like, and those records are real history, not corruption. They are
        // stamped and preserved so a repair can tell them apart later — what must never
        // happen again is believing them and writing zeroes back over the top.
        // The v1 shape is a bare dictionary of records keyed by app + 0x1F + menu path.
        // Checking the *keys* first is load-bearing: every Record field is optional, so any
        // JSON object at all decodes as an empty Record, and a v2 file that had merely lost
        // its `version` key "migrated" into a store whose three records were named
        // "records", "apps" and "settings" — then saved over the original two seconds
        // later. This is the one path that could destroy a readable file, in a loader whose
        // stated promise is that it never does.
        if looksLikeV1(data), let legacy = try? decoder.decode([String: Record].self, from: data) {
            file = StoreFile()
            file.records = legacy
            // Stamped here too. It only ran on the v2 branch, so a v1 file's records kept
            // `v: 0` and no flag — and one keystroke was then enough to lift the score off
            // zero, after which the next launch saw a record that no longer *looked* stale
            // and promoted it to v3. The lost score became undetectable, which is the one
            // thing the version field was added to prevent.
            _ = stampPreScoreRecords()
            debugLog("migrated v1 -> v2: \(legacy.count) records")
            scheduleSave()
            return
        }
        // A day stamp is not unique, and moveItem refuses to overwrite. The second
        // corruption in one day therefore failed the move, was swallowed by `try?`, and
        // logged success anyway — leaving the original in place for the next save to
        // overwrite. The name now carries the time and the result is checked.
        let stamp = Self.backupStamp.string(from: Clock.now())
        var backup = url.deletingLastPathComponent()
            .appendingPathComponent("learning.json.bak-\(stamp)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            attempt += 1
            backup = url.deletingLastPathComponent()
                .appendingPathComponent("learning.json.bak-\(stamp)-\(attempt)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            debugLog("unreadable store; preserved at \(backup.lastPathComponent), starting fresh")
        } catch {
            // Refusing to start is the safe answer: an empty store that cannot be set
            // aside will be written over the original within two seconds.
            readOnly = true
            debugLog("unreadable store AND could not preserve it (\(error)) — "
                     + "saving is disabled for this run so the file is not overwritten")
        }
    }

    // MARK: - events (called from UsageLog on the main queue)

    func noteKeyboardUse(app: String, path: [String], assisted: Bool) {
        let k = key(app, path)
        var r = file.records[k] ?? Record()
        settle(&r)
        r.kbUses += 1
        r.lastKbUse = Clock.now()

        if assisted {
            // Using the panel is the tool working, not evidence of recall. No credit and
            // no penalty — the score simply stops climbing while you are still looking.
            r.lastAssisted = Clock.now()
            debugLog("assisted  \(k) score=\(Int(r.score))")
        } else {
            let day = today()
            if r.gainedOn != day { r.gainedOn = day; r.gainedThatDay = 0 }
            let room = max(0, dailyGainCap - r.gainedThatDay)
            let gain = min(gainPerRecall, room)
            r.gainedThatDay += gain
            r.score = min(hallOfFameScore, r.score + gain)

            if !r.everUnaided && (r.mousePicks > 0 || r.lastAssisted != nil) {
                r.everUnaided = true
                appendEvent("unaided_conversion", app: app, key: k)
            }
            debugLog("unaided   \(k) +\(Int(gain)) -> \(Int(r.score))")
        }
        file.records[k] = r
        noteHallOfFame(k, app: app)
        scheduleSave()
    }

    func noteMousePick(app: String, path: [String]) {
        let k = key(app, path)
        var r = file.records[k] ?? Record()
        settle(&r)
        if r.score >= hallOfFameScore { appendEvent("relapsed", app: app, key: k) }
        r.mousePicks += 1
        r.lastMousePick = Clock.now()
        r.score = max(0, r.score - mousePenalty)
        r.hallOfFameLogged = r.score >= hallOfFameScore
        file.records[k] = r
        debugLog("mouse     \(k) -\(Int(mousePenalty)) -> \(Int(r.score))")
        scheduleSave()
    }

    /// Applies decay up to now and rebases the record, so every later arithmetic works on
    /// a current value. Called before any change and before any read.
    private func settle(_ r: inout Record) {
        defer { r.scoredAt = Clock.now() }
        guard let last = r.scoredAt else { return }
        let idle = Clock.now().timeIntervalSince(last) / 86_400 - decayGraceDays
        guard idle > 0 else { return }
        r.score = max(0, r.score - decayPerDay * idle)
    }

    private func settled(_ r: Record) -> Double {
        guard let last = r.scoredAt else { return r.score }
        let idle = Clock.now().timeIntervalSince(last) / 86_400 - decayGraceDays
        return idle > 0 ? max(0, r.score - decayPerDay * idle) : r.score
    }

    private func noteHallOfFame(_ k: String, app: String) {
        guard var r = file.records[k], r.score >= hallOfFameScore, !r.hallOfFameLogged else { return }
        r.hallOfFameLogged = true
        file.records[k] = r
        appendEvent("hall_of_fame", app: app, key: k)
    }

    /// M2 gate: proof that this app's AX layer actually reports selections.
    func noteSelectionSeen(app: String) {
        var a = file.apps[app] ?? AppRecord()
        a.selectionEventsSeen += 1
        file.apps[app] = a
        // This was the only mutator that did not schedule one, so the M2 gate survived
        // only if some unrelated change happened to write first. Losing it makes the panel
        // say "this app never reports selections", which is a false claim about the app.
        scheduleSave()
    }

    /// M2 denominator. Called off the panel's critical path, after the panel is shown.
    func noteObserved(app: String, paths: [[String]]) {
        var a = file.apps[app] ?? AppRecord()
        let before = a.observed.count
        for p in paths { a.observed.insert(p.joined(separator: "\u{1F}")) }
        guard a.observed.count != before else { return }   // no growth, no write
        file.apps[app] = a
        scheduleSave()
    }

    // MARK: - rendering queries

    func emphasis(app: String, path: [String]) -> Emphasis {
        let k = key(app, path)
        guard let r = file.records[k] else { return .none }
        let score = settled(r)

        if score >= hallOfFameScore { return .hallOfFame }
        // A recent mouse pick used to outrank the score and paint the row orange. Removed
        // on request. The mouse is still counted — `noteMousePick` still takes its penalty
        // off the score — so reaching for it still shows, as a lower gauge rather than as a
        // colour shouting at you.
        if score > 0 { return .learning(score / hallOfFameScore) }
        return daysSince(r.lastKbUse) < staleDays ? .learning(0) : .none
    }

    /// M2. nil when this app has never reported a selection, so no dishonest 0/N.
    func progress(app: String) -> (done: Int, total: Int)? {
        guard let a = file.apps[app], a.selectionEventsSeen > 0, !a.observed.isEmpty else { return nil }
        let live = a.observed
        let done = live.filter { p in
            guard let r = file.records[app + "\u{1F}" + p] else { return false }
            return settled(r) >= hallOfFameScore
        }.count
        return (done, live.count)
    }

    /// The score, 0…100, for the gauge. nil when there is nothing to show yet.
    func score(app: String, path: [String]) -> Int? {
        guard let r = file.records[key(app, path)] else { return nil }
        let value = settled(r)
        guard value > 0 || r.mousePicks > 0 else { return nil }
        return Int(value.rounded())
    }

    /// How often this item has been picked with the mouse. Orders the "still mousing"
    /// column: the one your hand reaches for most is the one worth learning first.
    func mousePicks(app: String, path: [String]) -> Int {
        file.records[key(app, path)]?.mousePicks ?? 0
    }

    /// Whether this is the v1 shape rather than a v2 file that lost its version key.
    private func looksLikeV1(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return false }
        // Every v1 key is "bundle-id 0x1F menu 0x1F item". A v2 file's top level is
        // version/records/apps/settings — plus `muted` in files written before that
        // feature was removed — none of which can contain the separator.
        return object.keys.allSatisfy { $0.contains("\u{1F}") }
    }

    /// Marks records written before the score model and brings them up to the current
    /// shape. Returns how many need a repair they cannot perform themselves.
    ///
    /// Runs once per load, before anything can be pressed: the discriminator is
    /// "no version, keyboard uses, and a zero score", and a single unaided press makes it
    /// false forever.
    private func stampPreScoreRecords() -> Int {
        var stale = 0
        for (key, var record) in file.records where record.v < Record.currentVersion {
            if record.kbUses > 0 && record.score == 0 {
                record.needsScoreRepair = true
                stale += 1
            }
            record.v = Record.currentVersion
            file.records[key] = record
        }
        if !file.records.isEmpty { scheduleSave() }
        return stale
    }

    /// How many records carry a shape older than the score model. Surfaced so a test and
    /// the launch log can both see it, rather than it being a fact only the file knows.
    var staleRecordCount: Int { file.records.values.filter(\.needsScoreRepair).count }

    func kbUses(app: String, path: [String]) -> Int {
        file.records[key(app, path)]?.kbUses ?? 0
    }

    // MARK: - mute ledger

    // MARK: - internals


    private func daysSince(_ d: Date?) -> Double {
        guard let d else { return .infinity }
        return Clock.now().timeIntervalSince(d) / 86_400
    }

    private func today() -> String { Self.dayStamp.string(from: Clock.now()) }

    private func key(_ app: String, _ path: [String]) -> String {
        app + "\u{1F}" + path.joined(separator: "\u{1F}")
    }

    /// Transitions must be logged as they happen: "relapsed this week" is not derivable
    /// from a state snapshot, and the weekly digest is built entirely from these.
    private func appendEvent(_ event: String, app: String, key: String) {
        let entry: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Clock.now()),
            "event": event, "app": app, "key": key,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = Data((json + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: eventsURL)
        }
        debugLog("event \(event) \(key)")
    }

    /// Writes immediately, bypassing the debounce. Tests must be able to observe the file
    /// without sleeping through a two-second timer.
    func flushForTesting() { write() }

    /// Writes now, for app termination. The debounce is two seconds and a menu-bar agent
    /// is quit without warning; every development restart in this project's history has
    /// been a `pkill`, which drops whatever was pending.
    func flush() {
        savePending = false
        write()
    }

    /// One writer, atomic. It used to be `data.write(to:)` with default options — truncate
    /// and rewrite in place — so a crash mid-write left a truncated file, which the loader
    /// then routed to the preserve-and-start-empty path. The regenerable weekly digest was
    /// already written atomically; the irreplaceable file was not.
    private func write() {
        guard !readOnly else { return }
        guard let data = try? JSONEncoder().encode(file) else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { debugLog("could not save learning.json: \(error)") }
    }

    /// Debounced: shortcut bursts (⌘Z ×20 in the first day's real data) would otherwise
    /// rewrite the whole file per keystroke.
    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.savePending = false
            self.write()
        }
    }
}
