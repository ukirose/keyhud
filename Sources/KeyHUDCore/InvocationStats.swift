import Foundation

/// M4 — the inverse KPI. Counts how often the panel was actually *shown* per ISO week.
///
/// The headline number is one the user wants to go DOWN. That inversion is the whole
/// point: a tool whose job is to make itself unnecessary must not score itself on
/// engagement, or it starts quietly rooting for your dependence. Nothing here rewards
/// opening the panel — it only reports the count and its direction.
///
/// The history file is read once at launch on a background queue and then kept live in
/// memory, so opening the status menu never parses anything.
final class InvocationStats {
    private var weeks: [String: Int] = [:]
    private let url: URL
    private var loaded = false

    private static let isoCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }()

    init() {
        url = DataDir.url.appendingPathComponent("invocations.jsonl")
    }

    static func weekKey(_ date: Date) -> String {
        let c = isoCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    func loadInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let text = try? String(contentsOf: self.url, encoding: .utf8) else {
                DispatchQueue.main.async { self?.loaded = true }
                return
            }
            var counts: [String: Int] = [:]
            let iso = ISO8601DateFormatter()
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let stamp = obj["t"] as? String, let date = iso.date(from: stamp) else { continue }
                // Entries predating the flag were, in practice, mostly real shows.
                if let shown = obj["shown"] as? Bool, !shown { continue }
                counts[Self.weekKey(date), default: 0] += 1
            }
            DispatchQueue.main.async {
                // Merge rather than assign: holds during the load must not be lost.
                for (k, v) in counts { self.weeks[k, default: 0] += v }
                self.loaded = true
                debugLog("invocation stats loaded: \(counts.count) weeks")
            }
        }
    }

    func noteShown(at date: Date) {
        weeks[Self.weekKey(date), default: 0] += 1
    }

    /// Most recent `count` ISO weeks, oldest first, as (label, count).
    func recentWeeks(_ count: Int = 4) -> [(label: String, count: Int)] {
        guard loaded else { return [] }
        let cal = Self.isoCalendar
        return (0..<count).reversed().compactMap { back in
            guard let date = cal.date(byAdding: .weekOfYear, value: -back, to: Clock.now()) else { return nil }
            let key = Self.weekKey(date)
            return (back == 0 ? "今週" : key, weeks[key] ?? 0)
        }
    }

    /// Direction of this week against the mean of the previous three. Down is good.
    func trend() -> String {
        let recent = recentWeeks(4)
        guard recent.count == 4 else { return "" }
        let prior = recent.dropLast().map(\.count)
        let mean = Double(prior.reduce(0, +)) / Double(prior.count)
        guard mean > 0 else { return "" }
        let current = Double(recent.last!.count)
        if current < mean * 0.85 { return "↓ 参照が減っています" }
        if current > mean * 1.15 { return "↑ 参照が増えています" }
        return "→ 横ばい"
    }
}
