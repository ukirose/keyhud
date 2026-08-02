import XCTest
@testable import KeyHUDCore

/// Decoding checked against every key equivalent on this machine, not against examples
/// chosen to match the implementation.
///
/// Four decoding bugs shipped in a row — private-use function keys rendered as "?",
/// control characters rendered as nothing, the Globe modifier silently dropped so window
/// tiling was labelled "⌃←", and shifted characters landing on no key at all. Each was
/// found by a person noticing a wrong label, and each fix addressed exactly that one
/// case. They are a single class of failure: macOS encodes key equivalents in more ways
/// than reading the headers suggests, so the only useful test is one that fails when *any*
/// unhandled encoding exists anywhere.
///
/// Regenerate the corpus with `./dev.sh corpus` after installing or updating apps.
final class AXCorpusTests: XCTestCase {

    private struct Entry {
        let app: String
        let path: [String]
        let parsed: String
        let cmdChar: String?
        let scalars: [String]
        let glyph: Int?
        let virtualKey: Int?
        let modifiers: Int
        let keyLabel: String
    }

    private static let corpus: [Entry] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ax-corpus.json")
        guard let data = try? Data(contentsOf: url),
              let byApp = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]]
        else { return [] }
        return byApp.flatMap { app, rows in
            rows.map { row in
                Entry(app: app,
                      path: row["path"] as? [String] ?? [],
                      parsed: row["parsed"] as? String ?? "",
                      cmdChar: row["cmdChar"] as? String,
                      scalars: row["cmdCharScalars"] as? [String] ?? [],
                      glyph: row["cmdGlyph"] as? Int,
                      virtualKey: row["cmdVirtualKey"] as? Int,
                      modifiers: row["cmdModifiers"] as? Int ?? 0,
                      keyLabel: row["keyLabel"] as? String ?? "")
            }
        }
    }()

    /// The decoder's answer *now* for this item, or its captured label if the item no
    /// longer decodes at all — which is itself a failure the replay test reports.
    ///
    /// This used to return `e.keyLabel` straight from the fixture, which the decoder had
    /// written there at capture time. Half of this file was therefore comparing the
    /// decoder against a frozen copy of its own output and would have passed with
    /// `keyEquivalent` deleted. Only three cases had been converted; these are the rest.
    private static func keyPart(of e: Entry) -> String { replay(e)?.1 ?? e.keyLabel }

    /// The decoder run *now*, over the raw attributes the corpus preserved.
    ///
    /// This is the difference between a test and a tautology. Every assertion below that
    /// reads `keyLabel` is comparing the decoder to a frozen copy of its own output, so it
    /// holds whatever the decoder does today — the suite would pass with `keyEquivalent`
    /// deleted. Replaying the inputs is what makes a regression fail.
    private static func replay(_ e: Entry) -> (Shortcut.Mods, String, Shortcut.Source)? {
        MenuScraper.keyEquivalent(cmdChar: e.cmdChar, cmdGlyph: e.glyph,
                                  cmdVirtualKey: e.virtualKey, cmdModifiers: e.modifiers)
    }

    func testCorpusIsPresent() {
        XCTAssertGreaterThan(Self.corpus.count, 500,
                             "run ./dev.sh corpus to capture key equivalents from running apps")
    }

    /// A key label that is empty, or a bare control character, or a private-use codepoint,
    /// draws as a blank column or a missing-glyph box. Every one of the shipped bugs
    /// showed up exactly here.
    func testEveryKeyLabelIsPrintable() {
        var bad: [String] = []
        for e in Self.corpus {
            let key = Self.keyPart(of: e)
            if key.isEmpty {
                bad.append("\(e.app) \(e.path.last ?? "?"): empty key")
                continue
            }
            for scalar in key.unicodeScalars where scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) {
                bad.append(String(format: "%@ %@: U+%04X unrenderable",
                                  e.app, e.path.last ?? "?", scalar.value))
            }
        }
        XCTAssertEqual(bad, [], "unhandled key-equivalent encodings:\n" + bad.prefix(15).joined(separator: "\n"))
    }

    /// The Globe bit was dropped, so "🌐⌃←" was displayed as "⌃←" — a chord that switches
    /// Spaces instead of tiling the window. Any item carrying 0x10 must say so.
    func testFunctionModifierIsNeverDropped() {
        let fnItems = Self.corpus.filter { $0.modifiers & 0x10 != 0 }
        XCTAssertFalse(fnItems.isEmpty, "macOS 15 ships Globe-based window tiling; the corpus should contain some")
        let dropped = fnItems.filter { !$0.parsed.contains("fn") }
        XCTAssertEqual(dropped.map { "\($0.app) \($0.path.last ?? "")" }, [])
    }

    /// Anything typed on the alphanumeric block must resolve to a cap. Restricting the
    /// claim to ASCII is the point: it is the set where a miss can only mean a matching
    /// bug, whereas 🎤 (Dictation) and ⌧ (Clear) legitimately have no key on any board and
    /// belong in the off-board legend. An assertion that also covered those would have to
    /// be weakened with exceptions until it stopped catching anything.
    func testEveryTypeableKeyResolvesToACap() {
        KeyboardLayout.load()
        let unplaced = Self.corpus.compactMap { e -> String? in
            let key = Self.keyPart(of: e)
            guard key.count == 1, let scalar = key.unicodeScalars.first,
                  scalar.isASCII, scalar.value > 0x20 else { return nil }
            return KeyboardLayout.locate(key) == nil ? "\(key) (\(e.app))" : nil
        }
        XCTAssertEqual(Set(unplaced).sorted(), [],
                       "typeable keys the list shows but the board cannot place")
    }

    /// The keys that genuinely have no cap, pinned so a new one is noticed rather than
    /// quietly vanishing into the off-board legend.
    func testUnplaceableKeysAreOnlyTheKnownOnes() {
        KeyboardLayout.load()
        let unplaced = Set(Self.corpus.compactMap { e -> String? in
            let key = Self.keyPart(of: e)
            guard !key.isEmpty, KeyboardLayout.locate(key) == nil else { return nil }
            return key
        })
        // 🎤 Dictation, ⌧ Clear, and the function keys above F12 — none exist on an HHKB.
        let known: Set<String> = ["🎤", "⌧"]
        let unexpected = unplaced.subtracting(known).filter { !$0.hasPrefix("F") }
        XCTAssertEqual(unexpected.sorted(), [],
                       "a key with no cap that is not on the known list — either the board "
                       + "is missing it or the decoder produced something odd")
    }

    /// Two different commands on the same chord means the panel shows a duplicate the
    /// user cannot act on — usually a sign a modifier was dropped during decoding.
    func testNoTwoCommandsClaimTheSameChordInOneApp() {
        var byApp: [String: [String: [String]]] = [:]
        for e in Self.corpus where !e.parsed.isEmpty {
            byApp[e.app, default: [:]][e.parsed, default: []].append(e.path.last ?? "?")
        }
        var collisions: [String] = []
        for (app, chords) in byApp {
            for (chord, names) in chords where Set(names).count > 1 {
                collisions.append("\(app) \(chord): \(Set(names).sorted().joined(separator: " / "))")
            }
        }
        // Menu bars legitimately repeat a chord across contexts (a Close in two places),
        // so this is a budget rather than a prohibition — a regression shows as a jump.
        XCTAssertLessThan(collisions.count, 25,
                          "duplicate chords:\n" + collisions.sorted().prefix(20).joined(separator: "\n"))
    }
}

extension AXCorpusTests {
    /// Every F-key binding on this machine, run through the real filter.
    ///
    /// The unit test for this uses four hand-written shortcuts; this one uses the whole
    /// captured corpus, so a binding whose key label is spelled some way I did not think
    /// of still has to disappear. macOS is spending F1–F12 on brightness, Mission Control
    /// and volume, and this keyboard has no way to ask for the F-key instead.
    func testNoFunctionKeyBindingSurvivesTheFilterOnThisKeyboard() {
        let fKeys = Self.corpus.filter {
            $0.keyLabel.first == "F" && Int($0.keyLabel.dropFirst()).map { (1...12).contains($0) } == true
        }
        XCTAssertFalse(fKeys.isEmpty, "the corpus should contain IDE F-key bindings to filter")

        let byMods = Dictionary(grouping: fKeys, by: \.modifiers)
        for (rawAX, entries) in byMods {
            let mods = MenuScraper.decodeModifiers(rawAX)
            guard mods.isReachable else { continue }
            let items = entries.map {
                Shortcut(path: $0.path, mods: mods, keyLabel: $0.keyLabel, source: .char,
                         element: nil, enabled: true)
            }
            let content = PanelContent.resolve(
                appName: "IDE", appKey: "ide", mods: mods,
                sections: [MenuSection(name: "m", items: items)],
                learning: nil, hideDisabled: true, hideMastered: false,
                canTypeFunctionKeys: false)
            XCTAssertTrue(content.rows.isEmpty,
                          "\(mods.glyphs) F-keys are unpressable here and must not be listed")
            XCTAssertNil(content.combinations.first { $0.count > 0 },
                         "nor counted in the bar")
        }
    }
}

extension AXCorpusTests {
    /// Every key equivalent on this machine, decoded again from its raw attributes.
    ///
    /// The corpus's whole purpose — stated at the top of this file — is to fail when any
    /// unhandled encoding exists. It could not, because it only ever read back the label
    /// the decoder had already written into the fixture. This replays the four raw
    /// attributes instead, so the decoder is being asked the question rather than shown
    /// its own answer.
    func testTheDecoderStillAgreesWithWhatItProducedForEveryCapturedItem() {
        var mismatches: [String] = []
        var decoded = 0
        for e in Self.corpus {
            guard let (mods, key, _) = Self.replay(e) else {
                if !e.keyLabel.isEmpty {
                    mismatches.append("\(e.app) \(e.path.joined(separator: "/")): "
                                      + "was '\(e.keyLabel)', now nothing")
                }
                continue
            }
            decoded += 1
            if key != e.keyLabel {
                mismatches.append("\(e.app) \(e.path.joined(separator: "/")): "
                                  + "was '\(e.keyLabel)', now '\(key)'")
            }
            if mods != MenuScraper.decodeModifiers(e.modifiers) {
                mismatches.append("\(e.app) \(e.path.joined(separator: "/")): modifiers")
            }
        }
        XCTAssertGreaterThan(decoded, 500, "the replay must actually reach the decoder")
        XCTAssertEqual(mismatches.count, 0,
                       "decoding changed for \(mismatches.count) captured items:\n"
                       + mismatches.prefix(10).joined(separator: "\n"))
    }

    /// The property the four shipped bugs all violated, checked against a live decode
    /// rather than against the fixture's own copy.
    func testNoRawEncodingEscapesTheDecoderOnReplay() {
        var raw: [String] = []
        for e in Self.corpus {
            guard let (_, key, _) = Self.replay(e), let first = key.unicodeScalars.first
            else { continue }
            // A control character, a private-use codepoint, or an empty label means an
            // encoding fell through untranslated.
            if key.isEmpty || first.value < 0x20 || (0xF700...0xF8FF).contains(first.value) {
                raw.append("\(e.app) \(e.path.joined(separator: "/")): U+\(String(first.value, radix: 16))")
            }
        }
        XCTAssertEqual(raw.count, 0, "unhandled encodings:\n" + raw.prefix(10).joined(separator: "\n"))
    }

    /// Which decoder branches this machine's applications actually reach.
    ///
    /// Measured: none of the 980 captured items decode through the glyph attribute. A
    /// hundred of them *carry* one — the corpus has cmdGlyph 2, 23, 104, 106, 150 — but
    /// every one of those also carries a usable cmdChar, and char is checked first. The
    /// glyph table is a fallback that has never once been needed here.
    ///
    /// That is worth knowing rather than asserting away, so this records it. The branch
    /// itself is covered directly in `KeyEquivalentDecodingTests`, which the corpus cannot
    /// do because no captured input reaches it.
    func testWhichDecodingBranchesTheCapturedAppsReach() {
        var sources: [Shortcut.Source: Int] = [:]
        for e in Self.corpus {
            if let (_, _, source) = Self.replay(e) { sources[source, default: 0] += 1 }
        }
        XCTAssertGreaterThan(sources[.char] ?? 0, 500)
        XCTAssertEqual(sources[.glyph] ?? 0, 0,
                       "a glyph-decoded item appeared; the note above is now out of date")
    }
}
