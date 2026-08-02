import Foundation

/// M5 — a weekly plain-markdown report, generated locally from the JSONL logs. No AI,
/// no network, no account: it is a `grep` and a sort, written to a file.
///
/// This is where celebration is allowed to live. The panel itself stays quiet because it
/// sits in the middle of a keystroke; a file you read on purpose, once a week, costs
/// nothing at the moment of use.
enum Digest {
    private static let iso = ISO8601DateFormatter()

    static func generateIfNeeded(dataDir: URL) {
        DispatchQueue.global(qos: .utility).async {
            let digestDir = dataDir.appendingPathComponent("digests")
            try? FileManager.default.createDirectory(at: digestDir, withIntermediateDirectories: true)

            guard let lastWeek = Calendar(identifier: .iso8601)
                .date(byAdding: .weekOfYear, value: -1, to: Clock.now()) else { return }
            let key = InvocationStats.weekKey(lastWeek)
            let path = digestDir.appendingPathComponent("\(key).md")
            guard !FileManager.default.fileExists(atPath: path.path) else { return }

            guard let body = render(week: key, dataDir: dataDir) else { return }
            try? body.write(to: path, atomically: true, encoding: .utf8)
            debugLog("digest written: \(path.lastPathComponent)")
        }
    }

    /// Force-generate the current week, for the status-menu item.
    static func generateCurrent(dataDir: URL) -> URL? {
        let digestDir = dataDir.appendingPathComponent("digests")
        try? FileManager.default.createDirectory(at: digestDir, withIntermediateDirectories: true)
        let key = InvocationStats.weekKey(Clock.now())
        guard let body = render(week: key, dataDir: dataDir) else { return nil }
        let path = digestDir.appendingPathComponent("\(key).md")
        try? body.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func render(week: String, dataDir: URL) -> String? {
        let events = readJSONL(dataDir.appendingPathComponent("events.jsonl"), week: week)
        let picks = readJSONL(dataDir.appendingPathComponent("menu-picks.jsonl"), week: week)
        guard !events.isEmpty || !picks.isEmpty else { return nil }

        func label(_ o: [String: Any]) -> String {
            if let path = o["path"] as? [String] { return path.joined(separator: " ▸ ") }
            if let k = o["key"] as? String {
                return k.components(separatedBy: "\u{1F}").dropFirst().joined(separator: " ▸ ")
            }
            return (o["item"] as? String) ?? "?"
        }
        func section(_ title: String, _ lines: [String]) -> String {
            lines.isEmpty ? "" : "\n## \(title)\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }

        // "hall_of_fame", not "graduated". The scoring rewrite renamed the event at the
        // producer and not here, so the headline count was pinned at zero and the section
        // never rendered — while every real graduation sat unread in events.jsonl.
        let graduated = events.filter { $0["event"] as? String == "hall_of_fame" }.map(label)
        let relapsed = events.filter { $0["event"] as? String == "relapsed" }.map(label)
        let converted = events.filter { $0["event"] as? String == "unaided_conversion" }.map(label)

        var offenders: [String: Int] = [:]
        for p in picks where (p["viaMenu"] as? Bool == true) && (p["hasShortcut"] as? Bool == true) {
            offenders[label(p), default: 0] += 1
        }
        let topOffenders = offenders.sorted { $0.value > $1.value }.prefix(10)
            .map { "\($0.key) — マウス \($0.value)回" }

        var out = "# KeyHUD \(week)\n"
        out += "\n覚えたショートカット \(graduated.count) · 初めて自力で押した \(converted.count)"
        out += " · 忘れて戻った \(relapsed.count)\n"
        out += section("卒業（自力で使えるようになった）", graduated)
        out += section("初めて自力で押せた", converted)
        out += section("退行（また マウスに戻った）", relapsed)
        out += section("マウス常習犯（ショートカットがあるのに手が伸びていない）", topOffenders)
        if graduated.isEmpty && converted.isEmpty && relapsed.isEmpty && topOffenders.isEmpty {
            out += "\n動きなし。\n"
        }
        return out
    }

    private static func readJSONL(_ url: URL, week: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = obj["t"] as? String, let date = iso.date(from: stamp),
                  InvocationStats.weekKey(date) == week else { return nil }
            return obj
        }
    }
}
