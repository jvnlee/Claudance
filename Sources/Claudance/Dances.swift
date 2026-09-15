import Foundation

enum DanceStyle: String, CaseIterable {
    case classic
    case hiphop
    case jazz
    case disco
    case floating
    case robot
    case twist
    case spin

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .hiphop: return "Hip-hop"
        case .jazz: return "Jazz"
        case .disco: return "Disco"
        case .floating: return "Floating"
        case .robot: return "Robot"
        case .twist: return "Twist"
        case .spin: return "Spin"
        }
    }

    var tempo: Double {
        switch self {
        case .robot: return 0.5
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
        case .hiphop: return hipHop(phase, energy)
        case .jazz: return jazz(phase, energy)
        case .disco: return disco(phase, energy)
        case .floating: return floating(phase, energy)
        case .robot: return robot(phase, energy)
        case .twist: return twist(phase, energy)
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

    private static func hipHop(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let step = sin(phase * 0.5)
        let beat = abs(sin(phase))
        let dip = 1 - beat
        var spec = ClawdDrawSpec()
        spec.frame = ClawdFrame.arms(.down, legs: abs(step) < 0.5 ? .together : .apart)
        spec.shift = 1.2 * energy * step
        spec.leanRadians = -0.08 * energy * step
        spec.bob = ground + 0.5 * energy * beat
        spec.scaleY = 1 - 0.10 * energy * dip
        spec.scaleX = 1 + 0.06 * energy * dip
        return spec
    }

    private static func jazz(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        var spec = ClawdDrawSpec()
        if phase < 2 * .pi {
            let kick = sin(phase)
            let lift = abs(kick)
            let legs: LegPose = kick > 0.35 ? .kickRight : (kick < -0.35 ? .kickLeft : .apart)
            spec.frame = ClawdFrame(legs: legs)
            spec.leanRadians = 0.12 * energy * kick
            spec.bob = ground + 0.9 * energy * lift
            spec.scaleY = 1 + 0.04 * energy * lift
            spec.scaleX = 1 - 0.03 * energy * lift
        } else {
            let hands = sin((phase - 2 * .pi) * 0.5)
            let shimmy = sin(phase * 2) * hands
            spec.frame = ClawdFrame.arms(hands > 0.3 ? .up : .rest)
            spec.leanRadians = 0.05 * energy * shimmy
            spec.scaleX = 1 + 0.06 * energy * shimmy
            spec.bob = ground + 0.6 * energy * hands
            spec.scaleY = 1 + 0.05 * energy * hands
        }
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

    private static func twist(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let twist = sin(phase)
        let turn = abs(twist)
        let low = (1 - cos(phase * 0.5)) / 2
        let legs: LegPose = twist > 0.4 ? .slide(2) : (twist < -0.4 ? .slide(-2) : .apart)
        var spec = ClawdDrawSpec()
        spec.frame = ClawdFrame(legs: legs)
        spec.scaleX = 1 - 0.12 * energy * turn
        spec.scaleY = 1 - 0.08 * energy * low
        spec.leanRadians = 0.06 * energy * twist
        spec.bob = ground
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

    private struct RobotKey {
        var frame: ClawdFrame
        var lean: Double
        var shift: Double
        var crouch: Double
    }

    private static let robotKeys: [RobotKey] = [
        RobotKey(frame: .apart, lean: 0, shift: 0, crouch: 0),
        RobotKey(frame: ClawdFrame(leftArm: .up), lean: 0.08, shift: 0, crouch: 0),
        RobotKey(frame: ClawdFrame.arms(.up), lean: 0, shift: 0, crouch: 0),
        RobotKey(frame: ClawdFrame(rightArm: .up), lean: -0.08, shift: 0, crouch: 0),
        RobotKey(frame: .together, lean: 0, shift: 0, crouch: 1),
        RobotKey(frame: ClawdFrame.arms(.down, legs: .slide(-2)), lean: 0.06, shift: -0.8, crouch: 0),
        RobotKey(frame: ClawdFrame.arms(.down, legs: .slide(2)), lean: -0.06, shift: 0.8, crouch: 0),
        RobotKey(frame: .apart, lean: 0, shift: 0, crouch: 0.5),
    ]

    private static func robot(_ phase: Double, _ energy: Double) -> ClawdDrawSpec {
        let keys = robotKeys
        let position = phase / loopPhase * Double(keys.count)
        let index = min(keys.count - 1, Int(position))
        let snap = min(1, (position - Double(index)) / 0.2)
        let blend = snap * (2 - snap)
        let current = keys[index]
        let previous = keys[(index + keys.count - 1) % keys.count]
        func mix(_ from: Double, _ to: Double) -> Double { from + (to - from) * blend }
        let crouch = energy * mix(previous.crouch, current.crouch)
        var spec = ClawdDrawSpec()
        spec.frame = current.frame
        spec.leanRadians = energy * mix(previous.lean, current.lean)
        spec.shift = energy * mix(previous.shift, current.shift)
        spec.scaleY = 1 - 0.10 * crouch
        spec.scaleX = 1 + 0.05 * crouch
        spec.bob = ground
        return spec
    }
}
