import Foundation

struct UsageCrossing {
    let label: String
    let threshold: Int

    var message: String {
        threshold >= 100 ? "\(label) limit reached!" : "\(label) limit at \(threshold)%!"
    }
}

final class UsageAlertTracker {

    static let thresholds = [90, 95, 100]

    private var announced: [String: [String: Int]] = [:]

    func evaluate(key: String, snapshot: UsageSnapshot, enabled: [Int]) -> [UsageCrossing] {
        var buckets: [(id: String, label: String, bucket: UsageBucket)] = []
        if let b = snapshot.fiveHour { buckets.append(("fiveHour", "5-hour", b)) }
        if let b = snapshot.sevenDay { buckets.append(("weekly", "Weekly", b)) }
        if !snapshot.scopedWeekly.isEmpty {
            for scoped in snapshot.scopedWeekly {
                buckets.append(("scoped.\(scoped.label)", scoped.label, scoped.bucket))
            }
        } else if let b = snapshot.sonnet {
            buckets.append(("sonnet", "Sonnet", b))
        }
        if snapshot.hasExtraUsage, let b = snapshot.extraUsage {
            buckets.append(("extra", "Extra usage", b))
        }

        var crossings: [UsageCrossing] = []
        var accountLevels = announced[key] ?? [:]

        for (id, label, bucket) in buckets {
            let crossed = Self.thresholds.last { bucket.percent >= $0 } ?? 0
            guard let level = accountLevels[id] else {
                accountLevels[id] = crossed
                continue
            }
            if crossed > level {
                if let threshold = enabled.filter({ $0 > level && $0 <= crossed }).max() {
                    crossings.append(UsageCrossing(label: label, threshold: threshold))
                }
                accountLevels[id] = crossed
            } else if level > 0, bucket.percent <= level - 20 {
                accountLevels[id] = crossed
            }
        }

        announced[key] = accountLevels
        return crossings
    }
}
