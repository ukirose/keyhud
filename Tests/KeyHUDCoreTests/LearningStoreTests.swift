import XCTest
@testable import KeyHUDCore

/// The learning score. Everything here is unobservable from outside — reaching 100 takes
/// about a week of real use and decaying back to zero takes a season — so without a
/// controllable clock the only way to check any of it was to wait.
final class LearningStoreTests: XCTestCase {
    private var dir: URL!
    private var store: LearningStore!

    private let app = "com.apple.TextEdit"
    private let path = ["編集", "取り消す"]

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyhud-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Clock.override = date("2026-08-01")
        store = LearningStore(directory: dir)
    }

    override func tearDown() {
        Clock.override = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f.date(from: iso)!
    }

    private func at(_ iso: String, _ body: () -> Void) {
        Clock.override = date(iso)
        body()
    }

    private func emphasis() -> String {
        switch store.emphasis(app: app, path: path) {
        case .learning: return "learning"
        case .hallOfFame: return "hallOfFame"
        case .none: return "none"
        }
    }

    // MARK: - scoring

    func testUnknownItemHasNoEmphasis() {
        XCTAssertEqual(emphasis(), "none")
    }

    /// A mouse pick used to paint the row orange, outranking whatever the score said.
    /// That display was removed on request; the mouse is still counted, and the only place
    /// it shows now is the number.
    func testAMousePickOnItsOwnEarnsNoEmphasis() {
        store.noteMousePick(app: app, path: path)
        XCTAssertEqual(emphasis(), "none", "the mouse no longer colours the row")
        XCTAssertEqual(store.score(app: app, path: path), 0)
    }

    /// 100 points at 8 a press, capped at 16 a day, is about a week of using something
    /// twice a day. The cap is what makes it a week rather than one determined sitting,
    /// and replaces the old "must span three distinct days" rule.
    func testReachesTheHallOfFameOverAboutAWeek() {
        for day in 20...27 {
            at("2026-08-\(day)") {
                store.noteKeyboardUse(app: app, path: path, assisted: false)
                store.noteKeyboardUse(app: app, path: path, assisted: false)
            }
        }
        XCTAssertEqual(emphasis(), "hallOfFame")
    }

    func testOneSittingCannotFarmTheScore() {
        at("2026-08-20") {
            for _ in 0..<20 { store.noteKeyboardUse(app: app, path: path, assisted: false) }
        }
        XCTAssertEqual(store.score(app: app, path: path), 16,
                       "a day's gain is capped; repetition is not recall on many occasions")
        XCTAssertEqual(emphasis(), "learning")
    }


    /// Using the panel is the tool working, not evidence of recall, so it earns nothing.
    func testAssistedPressesEarnNothing() {
        at("2026-08-20") { store.noteKeyboardUse(app: app, path: path, assisted: false) }
        let earned = store.score(app: app, path: path)
        at("2026-08-21") { store.noteKeyboardUse(app: app, path: path, assisted: true) }
        XCTAssertEqual(store.score(app: app, path: path), earned,
                       "looking it up must not move the bar")
    }

    // MARK: - decay

    /// Rust, made continuous: an item left alone slides back down the same bar it
    /// climbed, instead of falling off a cliff at a threshold.
    func testScoreDecaysWithDisuse() {
        testReachesTheHallOfFameOverAboutAWeek()
        XCTAssertEqual(store.score(app: app, path: path), 100)

        Clock.override = date("2026-09-05")
        let after = store.score(app: app, path: path) ?? 0
        XCTAssertLessThan(after, 100, "disuse costs points")
        XCTAssertGreaterThan(after, 60, "but slowly")
        XCTAssertEqual(emphasis(), "learning", "it is back in practice, not erased")

        // 100 points at a point a day, after three days' grace: a hall-of-famer untouched
        // for a season is back to nothing, which is about right for something forgotten.
        Clock.override = date("2027-01-01")
        XCTAssertNil(store.score(app: app, path: path),
                     "at zero there is no gauge to draw, so nothing is reported")
        XCTAssertEqual(emphasis(), "none", "back to an ordinary untouched shortcut")
    }

    /// A setback rather than a wipe. Losing everything to one slip made the number feel
    /// arbitrary; losing a quarter of it does not.
    func testMousePickCostsPointsWithoutErasingThem() {
        testReachesTheHallOfFameOverAboutAWeek()
        at("2026-08-28") { store.noteMousePick(app: app, path: path) }
        XCTAssertEqual(store.score(app: app, path: path), 75)
        // The setback shows in the gauge and nowhere else. It used to also flip the row to
        // orange, which is the display that was removed.
        XCTAssertEqual(emphasis(), "learning", "a setback is a lower gauge, not a new colour")
    }

    // MARK: - progress

    func testProgressIsHiddenUntilTheAppReportsASelection() {
        store.noteObserved(app: app, paths: [path, ["ファイル", "保存"]])
        XCTAssertNil(store.progress(app: app),
                     "an app whose AX layer never reports selections cannot honestly show 0/N")

        store.noteSelectionSeen(app: app)
        store.noteObserved(app: app, paths: [path, ["ファイル", "保存"]])
        XCTAssertEqual(store.progress(app: app)?.total, 2)
        XCTAssertEqual(store.progress(app: app)?.done, 0)
    }

    // MARK: - persistence

    func testStateSurvivesAReload() {
        store.noteMousePick(app: app, path: path)
        store.flushForTesting()

        let reloaded = LearningStore(directory: dir)
        XCTAssertEqual(reloaded.mousePicks(app: app, path: path), 1)
    }

    /// The loader used to swallow a decode failure and start empty, so one unreadable file
    /// became total data loss on the next save.
    func testUnreadableStoreIsPreservedRatherThanOverwritten() {
        try? "not json at all".write(to: dir.appendingPathComponent("learning.json"),
                                     atomically: true, encoding: .utf8)
        _ = LearningStore(directory: dir)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("learning.json.bak-") })
    }

    /// A v1 file is a bare dictionary of records with no `version` key. Tolerant decoding
    /// once made it decode "successfully" as an empty v2 store, which the next save then
    /// wrote over the top of.
    func testV1FileMigratesInsteadOfBeingDiscarded() {
        // The separator must be a JSON escape, not a raw 0x1F byte: a bare control
        // character inside a string is invalid JSON, and the store would correctly route
        // that to the preserve-and-restart path instead of the migration under test.
        let v1 = "{\"com.apple.TextEdit\\u001f取り消す\":{\"kbUses\":3,\"mousePicks\":1}}"
        try? v1.write(to: dir.appendingPathComponent("learning.json"),
                      atomically: true, encoding: .utf8)

        let migrated = LearningStore(directory: dir)
        XCTAssertEqual(migrated.mousePicks(app: "com.apple.TextEdit", path: ["取り消す"]), 1)
    }
}

extension LearningStoreTests {
    /// The shape change that already cost this machine twenty records.
    ///
    /// The model was rewritten from a five-step chain to a score. The *file* version was
    /// not bumped, because the file's shape had not changed — only the records' had. Every
    /// record field being `decodeIfPresent`, the old records loaded as valid, scored zero,
    /// and were written straight back out that way. Fifty-one unaided presses of one
    /// shortcut now read as untouched.
    func testARecordWrittenBeforeTheScoreModelIsRecognisedNotBelieved() throws {
        let old = """
        {"version":2,"records":{"com.apple.TextEdit\\u001f編集\\u001f取り消す":
          {"kbUses":51,"everUnaided":true,"score":0,"gainedOn":"","gainedThatDay":0,
           "mousePicks":0,"hallOfFameLogged":false}},
         "apps":{},"muted":[],"settings":{}}
        """
        try old.write(to: dir.appendingPathComponent("learning.json"),
                      atomically: true, encoding: .utf8)

        let loaded = LearningStore(directory: dir)
        XCTAssertEqual(loaded.kbUses(app: app, path: path), 51, "the counts are real history")
        XCTAssertEqual(loaded.staleRecordCount, 1,
                       "and the store must be able to say that this one's score is not")

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasPrefix("learning.json.bak-") },
                       "real history must not be routed to the corruption path either")
    }

    /// The discriminator, exercised.
    ///
    /// This used to write a record the current model had produced — `v: 3` — which the
    /// stamping loop skips before it ever reaches the "keyboard uses and a zero score"
    /// test. The assertion held because the branch was never entered; replacing the
    /// condition with `if true` would not have failed it. These three all reach it.
    func testWhatCountsAsALostScoreAndWhatDoesNot() throws {
        func staleCount(_ record: String) throws -> Int {
            try writeRecord(record)
            return LearningStore(directory: dir).staleRecordCount
        }
        // Old shape, real presses, nothing to show for them: the score was lost.
        XCTAssertEqual(try staleCount(#"{"score":0,"kbUses":51}"#), 1)
        // Old shape but never used — there is no score to have lost.
        XCTAssertEqual(try staleCount(#"{"score":0,"kbUses":0}"#), 0)
        // Old shape carrying a score: it survived the change, so nothing to repair.
        XCTAssertEqual(try staleCount(#"{"score":40,"kbUses":51}"#), 0)
        // Current shape is never inspected at all.
        XCTAssertEqual(try staleCount(#"{"v":3,"score":0,"kbUses":51}"#), 0)
    }

    /// A record the current model wrote is not stale, however low its score.
    func testAGenuineZeroIsNotMistakenForALostScore() {
        store.noteKeyboardUse(app: app, path: path, assisted: true)   // earns nothing
        store.flushForTesting()
        XCTAssertEqual(LearningStore(directory: dir).staleRecordCount, 0)
    }

    /// A pre-score-model record: real counts, no `v`, no score.
    private func writeStaleStore(repaired: Bool = false) throws {
        let record = repaired
            ? #"{"v":3,"needsScoreRepair":false,"score":40,"kbUses":51,"everUnaided":true}"#
            : #"{"score":0,"kbUses":51,"everUnaided":true,"gainedOn":"","mousePicks":0}"#
        // The separator is a raw 0x1F. It is written as a JSON escape here:
        // a bare control character is a compile error in Swift source and
        // invalid inside a JSON string.
        let key = "com.apple.TextEdit" + #"\u001f"# + "編集" + #"\u001f"# + "取り消す"
        let json = #"{"version":2,"records":{""# + key + #"":"# + record
            + #"},"apps":{},"muted":[],"settings":{}}"#
        try json.write(to: dir.appendingPathComponent("learning.json"),
                       atomically: true, encoding: .utf8)
    }

    /// The flag is an event, not a shape.
    ///
    /// Derived as `v < 3 && kbUses > 0 && score == 0`, it went out the moment the record
    /// earned its next point — so the count never converged, never reached zero, and came
    /// back on its own when decay returned the score to zero. Using a shortcut is not
    /// repairing its history.
    func testUsingAStaleRecordDoesNotCountAsRepairingIt() throws {
        try writeStaleStore()
        let loaded = LearningStore(directory: dir)
        XCTAssertEqual(loaded.staleRecordCount, 1)

        Clock.override = date("2026-08-20")
        loaded.noteKeyboardUse(app: app, path: path, assisted: false)
        XCTAssertGreaterThan(loaded.score(app: app, path: path) ?? 0, 0)
        XCTAssertEqual(loaded.staleRecordCount, 1, "a press is not a repair")

        loaded.flush()
        XCTAssertEqual(LearningStore(directory: dir).staleRecordCount, 1,
                       "and it survives a restart, because a repair still has not happened")
    }

    /// The flag round-trips.
    ///
    /// The old version of this wrote `v: 3` with the flag already false, so it proved only
    /// that a current record is not stamped — deleting the `needsScoreRepair` decode line
    /// would not have failed it. A raised flag has to survive a reload, and the repair
    /// tool's cleared one has to stick.
    func testTheRepairFlagSurvivesAReloadAndTheRepairClearsIt() throws {
        try writeRecord(#"{"v":3,"needsScoreRepair":true,"score":0,"kbUses":51}"#)
        XCTAssertEqual(LearningStore(directory: dir).staleRecordCount, 1,
                       "a raised flag must be read back, not defaulted away")

        try writeRecord(#"{"v":3,"needsScoreRepair":false,"score":40,"kbUses":51}"#)
        let repaired = LearningStore(directory: dir)
        XCTAssertEqual(repaired.staleRecordCount, 0)
        XCTAssertEqual(repaired.score(app: app, path: path), 40)
    }

    /// The v1 migration stamps too.
    ///
    /// It did not: only the v2 branch ran the loop, so a v1 file's records kept `v: 0`
    /// with no flag. One press then lifted the score off zero and the *next* launch saw a
    /// record that no longer looked stale, promoted it, and lost the evidence for good.
    func testAV1FileIsStampedSoItsLostScoresStayVisible() throws {
        let key = "com.apple.TextEdit" + #"\u001f"# + "編集" + #"\u001f"# + "取り消す"
        try (#"{""# + key + #"":{"kbUses":51,"score":0}}"#)
            .write(to: dir.appendingPathComponent("learning.json"),
                   atomically: true, encoding: .utf8)

        let migrated = LearningStore(directory: dir)
        XCTAssertEqual(migrated.staleRecordCount, 1)
        migrated.flush()

        // The press that used to erase the evidence.
        let reopened = LearningStore(directory: dir)
        Clock.override = date("2026-08-20")
        reopened.noteKeyboardUse(app: app, path: path, assisted: false)
        reopened.flush()
        XCTAssertEqual(LearningStore(directory: dir).staleRecordCount, 1,
                       "the flag outlives the score going non-zero")
    }

    private func writeRecord(_ json: String) throws {
        let key = "com.apple.TextEdit" + #"\u001f"# + "編集" + #"\u001f"# + "取り消す"
        let doc = #"{"version":2,"records":{""# + key + #"":"# + json
            + #"},"apps":{},"muted":[],"settings":{}}"#
        try doc.write(to: dir.appendingPathComponent("learning.json"),
                      atomically: true, encoding: .utf8)
    }

    /// The store is written atomically, so a crash mid-write cannot truncate it into the
    /// corruption path.
    func testTheStoreIsReadableAfterEveryWrite() throws {
        for i in 0..<20 {
            store.noteKeyboardUse(app: app, path: ["編集", "項目\(i)"], assisted: false)
            store.flush()
            let data = try Data(contentsOf: dir.appendingPathComponent("learning.json"))
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "write \(i) left the file unparseable")
        }
    }

    /// The one mutator that never scheduled a save.
    func testASelectionSightingSurvivesARestart() {
        store.noteSelectionSeen(app: app)
        store.noteObserved(app: app, paths: [path])
        store.flush()
        XCTAssertNotNil(LearningStore(directory: dir).progress(app: app),
                        "losing this makes the panel claim the app never reports selections")
    }
}

extension LearningStoreTests {
    /// The one path in the loader that could destroy a readable file.
    ///
    /// `version` is required at the top level, so a v2 file that lost that one key fell to
    /// the v1 branch — where every Record field is optional, so `{"records":…,"apps":…}`
    /// decoded happily as three empty records named "records", "apps" and "settings", and
    /// the debounced save wrote them over the original two seconds later.
    func testAV2FileMissingItsVersionIsPreservedNotMigrated() throws {
        let mangled = """
        {"records":{"com.apple.TextEdit\\u001f編集\\u001f取り消す":{"v":3,"score":40}},
         "apps":{},"muted":[],"settings":{}}
        """
        try mangled.write(to: dir.appendingPathComponent("learning.json"),
                          atomically: true, encoding: .utf8)

        let loaded = LearningStore(directory: dir)
        XCTAssertEqual(loaded.score(app: app, path: path), nil,
                       "it must not be read as a store of empty records")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("learning.json.bak-") },
                      "the original must be set aside, not migrated into nonsense")
    }

    /// And a genuine v1 file still migrates. Its keys carry the 0x1F separator, which is
    /// what tells the two apart.
    func testAGenuineV1FileStillMigrates() throws {
        let v1 = "{\"com.apple.TextEdit\\u001f取り消す\":{\"kbUses\":3,\"mousePicks\":1}}"
        try v1.write(to: dir.appendingPathComponent("learning.json"),
                     atomically: true, encoding: .utf8)
        XCTAssertEqual(LearningStore(directory: dir).mousePicks(app: "com.apple.TextEdit",
                                                                path: ["取り消す"]), 1)
    }
}
