import Foundation

enum DanceStyle: String, CaseIterable {
    case classic
    case disco
    case floating
    case spin

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .disco: return "Disco"
        case .floating: return "Floating"
        case .spin: return "Spin"
        }
    }

    var tempo: Double {
        switch self {
        case .floating: return 0.4
        case .spin: return 0.8
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
        case .classic: return classic(phase, energy)
        case .disco: return disco(phase, energy)
        case .floating: return floating(phase, energy)
        case .spin: return spin(phase, energy)
        }
    }

    private static func classic(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
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

    private static func disco(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
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

    private static func floating(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
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
        var spec = ClawdDrawSpec()
        if phase < 2 * .pi {
            let bounce = abs(sin(phase))
            spec.frame = ClawdFrame(legs: bounce < 0.5 ? .together : .apart)
            spec.bob = ground + 1.2 * energy * bounce
            spec.scaleY = 1 + 0.06 * energy * bounce
            spec.scaleX = 1 - 0.05 * energy * bounce
            spec.leanRadians = -0.08 * energy * sin(phase * 0.5)
        } else {
            let progress = (phase - 2 * .pi) / (2 * .pi)
            let eased = progress * progress * (3 - 2 * progress)
            let facing = cos(2 * .pi * eased)
            let jump = sin(.pi * progress)
            spec.frame = ClawdFrame(legs: jump > 0.3 ? .together : .apart, eyes: facing >= 0 ? .open : .hidden)
            spec.scaleX = max(0.1, abs(facing))
            spec.bob = ground + 2.0 * energy * jump
            spec.scaleY = 1 + 0.05 * energy * jump
        }
        return spec
    }
}
