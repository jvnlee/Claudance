import Foundation

struct ClusterOrder {

    private static let dwell: TimeInterval = 1.5
    private static let slideTimeConstant: Double = 0.16
    private static let settleEpsilon: CGFloat = 0.002

    private var seeds: [String: UInt64] = [:]
    private var committed: [String] = []
    private var pending: [String] = []
    private var pendingSince: TimeInterval = 0
    private var slots: [String: CGFloat] = [:]

    var order: [String] { committed }

    func slot(_ key: String) -> CGFloat { slots[key] ?? 0 }

    mutating func update(_ members: [(key: String, snapshot: ActivitySnapshot)],
                         now: TimeInterval, dt: Double) {
        for member in members where seeds[member.key] == nil {
            seeds[member.key] = UInt64.random(in: 0...UInt64.max)
        }

        let desired = members.sorted(by: precedes).map(\.key)

        if Set(desired) != Set(committed) {
            committed = desired
            pending = []
            slots = slots.filter { desired.contains($0.key) }
            for (index, key) in committed.enumerated() { slots[key] = CGFloat(index) }
        } else if desired != committed {
            if desired == pending {
                if now - pendingSince >= Self.dwell {
                    committed = desired
                    pending = []
                }
            } else {
                pending = desired
                pendingSince = now
            }
        } else {
            pending = []
        }

        let rate = CGFloat(1 - exp(-dt / Self.slideTimeConstant))
        for (index, key) in committed.enumerated() {
            let target = CGFloat(index)
            var position = slots[key] ?? target
            position += (target - position) * rate
            if abs(target - position) < Self.settleEpsilon { position = target }
            slots[key] = position
        }
    }

    private func precedes(_ a: (key: String, snapshot: ActivitySnapshot),
                          _ b: (key: String, snapshot: ActivitySnapshot)) -> Bool {
        let rankA = Self.rank(a.snapshot.state)
        let rankB = Self.rank(b.snapshot.state)
        if rankA != rankB { return rankA < rankB }
        if a.snapshot.workingCount != b.snapshot.workingCount {
            return a.snapshot.workingCount > b.snapshot.workingCount
        }
        if a.snapshot.presentCount != b.snapshot.presentCount {
            return a.snapshot.presentCount > b.snapshot.presentCount
        }
        let seedA = seeds[a.key] ?? 0
        let seedB = seeds[b.key] ?? 0
        if seedA != seedB { return seedA < seedB }
        return a.key < b.key
    }

    private static func rank(_ state: ClaudeActivity) -> Int {
        switch state {
        case .working: return 0
        case .waiting: return 1
        case .idle: return 2
        case .rest: return 3
        }
    }
}
