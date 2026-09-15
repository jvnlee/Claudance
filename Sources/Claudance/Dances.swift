import Foundation

enum DanceStyle: String, CaseIterable {
    case bounce
    case wave
    case float
    case spin

    var title: String {
        switch self {
        case .bounce: return "Bounce"
        case .wave: return "Wave"
        case .float: return "Float"
        case .spin: return "Spin"
        }
    }

    var tempo: Double {
        switch self {
        case .float: return 0.4
        case .spin: return 0.6
        default: return 1
        }
    }
}

enum DanceSetting: RawRepresentable, Equatable {
    case style(DanceStyle)
    case shuffle

    static let all: [DanceSetting] = DanceStyle.allCases.map(DanceSetting.style) + [.shuffle]

    init?(rawValue: String) {
        if rawValue == "shuffle" {
            self = .shuffle
        } else if let style = DanceStyle(rawValue: rawValue) {
            self = .style(style)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .style(let style): return style.rawValue
        case .shuffle: return "shuffle"
        }
    }

    var title: String {
        switch self {
        case .style(let style): return style.title
        case .shuffle: return "Shuffle"
        }
    }
}

extension Animator {

    private static let ground = ClawdDrawSpec.groundLevel

    static func dance(_ style: DanceStyle, phase: Double, energy: Double) -> ClawdDrawSpec {
        switch style {
        case .bounce: return bounce(phase, energy)
        case .wave: return wave(phase, energy)
        case .float: return float(phase, energy)
        case .spin: return spin(phase, energy)
        }
    }

    private static func bounce(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let bounce = abs(sin(phase))
        let stretch = (bounce - 0.5) * 2
        var spec = ClawdDrawSpec()
        spec.frame = bounce < 0.5 ? .together : .apart
        spec.bob = ground + 2.35 * energy * bounce
        spec.scaleY = 1 + 0.13 * energy * stretch
        spec.scaleX = 1 - 0.11 * energy * stretch
        spec.leanRadians = 0.16 * energy * sin(phase * 0.5)
        return spec
    }

    private static func wave(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let point = sin(phase * 0.5)
        let bounce = abs(sin(phase))
        let stretch = (bounce - 0.5) * 2
        var spec = ClawdDrawSpec()
        if point > 0.25 {
            spec.frame = ClawdFrame(leftArm: .down, rightArm: .up)
        } else if point < -0.25 {
            spec.frame = ClawdFrame(leftArm: .up, rightArm: .down)
        }
        spec.bob = ground + 0.8 * energy * bounce
        spec.scaleY = 1 + 0.06 * energy * stretch
        spec.scaleX = 1 - 0.04 * energy * stretch
        spec.leanRadians = -0.07 * energy * point
        spec.shift = 0.5 * energy * point
        return spec
    }

    private static func float(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let drift = sin(phase * 0.5)
        let velocity = cos(phase * 0.5)
        let rise = sin(phase)
        let legs: LegPose = velocity > 0.3 ? .slide(-1) : (velocity < -0.3 ? .slide(1) : .apart)
        var spec = ClawdDrawSpec()
        spec.frame = ClawdFrame(legs: legs, eyes: .closed)
        spec.shift = 1.4 * energy * drift
        spec.leanRadians = 0.06 * energy * velocity
        spec.bob = ground + 1.8 * energy + 0.4 * energy * rise
        return spec
    }

    private static func spin(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let t = phase / loopPhase
        var compress = 1.0
        var facing = 1.0
        var lift = 0.0
        switch t {
        case ..<0.09:
            compress = blend(1, -0.6, easeOut(t / 0.09))
        case ..<0.53:
            let air = (t - 0.09) / 0.44
            lift = 4 * air * (1 - air)
            compress = -0.6 * max(0, 1 - air / 0.3)
            facing = cos(2 * .pi * smoothStep(air))
        case ..<0.62:
            compress = 0.75 * easeOut((t - 0.53) / 0.09)
        default:
            compress = blend(0.75, 1, smoothStep((t - 0.62) / 0.38))
        }
        var spec = ClawdDrawSpec()
        spec.frame = ClawdFrame(eyes: facing >= 0 ? .open : .hidden)
        spec.bob = ground + 3.0 * energy * lift
        spec.scaleY = 1 - 0.22 * energy * compress
        spec.scaleX = max(0.1, abs(facing)) * (1 + 0.12 * energy * compress)
        return spec
    }

    private static func smoothStep(_ x: Double) -> Double {
        let clamped = min(1, max(0, x))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func easeOut(_ x: Double) -> Double {
        let clamped = min(1, max(0, x))
        return 1 - (1 - clamped) * (1 - clamped)
    }

    private static func blend(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + (to - from) * t
    }
}
