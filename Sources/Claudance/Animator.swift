import AppKit

struct Animator {

    private(set) var phase: Double = 0
    private var style: DanceStyle?
    private var speed: Double = 0
    private var energy: Double = 0
    private var lastState: ClaudeActivity = .rest
    private var lastDance: DanceSetting?

    mutating func update(_ snap: ActivitySnapshot, dance: DanceSetting, dt: Double) -> ClawdDrawSpec {
        resolveStyle(dance, state: snap.state)
        let current = style ?? .bounce

        let targetSpeed: Double
        let targetEnergy: Double

        switch snap.state {
        case .working:
            let a = snap.activity
            targetSpeed = (9 + a * 12) * current.tempo
            targetEnergy = 0.6 + 0.4 * a
        case .waiting:
            targetSpeed = 7
            targetEnergy = 0.6
        case .idle:
            targetSpeed = 2.4
            targetEnergy = 0.30
        case .rest:
            targetSpeed = 0
            targetEnergy = 0
        }

        let k = 1 - exp(-dt / 0.18)
        speed += (targetSpeed - speed) * k
        energy += (targetEnergy - energy) * k

        phase += speed * dt
        while phase > Self.loopPhase { phase -= Self.loopPhase }

        return Self.pose(state: snap.state, phase: phase, energy: energy, style: current)
    }

    private mutating func resolveStyle(_ dance: DanceSetting, state: ClaudeActivity) {
        defer {
            lastState = state
            lastDance = dance
        }
        switch dance {
        case .style(let fixed):
            style = fixed
        case .shuffle:
            let entering = state == .working && lastState != .working
            guard entering || lastDance != .shuffle else { return }
            style = DanceStyle.allCases.filter { $0 != style }.randomElement()
        }
    }

    static let loopPhase = 4 * Double.pi

    static func pose(state: ClaudeActivity, phase: Double, energy: Double,
                     style: DanceStyle = .bounce) -> ClawdDrawSpec {
        let bounce = abs(sin(phase))
        let s = (bounce - 0.5) * 2
        let ground = ClawdDrawSpec.groundLevel

        var spec = ClawdDrawSpec()

        switch state {
        case .rest:
            spec.frame = .apart
            spec.closedEyes = true
            spec.alpha = 0.8
            spec.bob = ground

        case .idle:
            spec.frame = .apart
            spec.bob = ground + bounce * 1.0 * energy
            spec.leanRadians = 0.06 * sin(phase * 0.5)
            spec.scaleY = 1 + 0.04 * s
            spec.scaleX = 1 - 0.03 * s
            spec.alpha = 0.95

        case .waiting:
            spec.frame = .apart
            spec.bob = ground + bounce * 1.6
            spec.leanRadians = 0.10 * sin(phase)

        case .working:
            return dance(style, phase: phase, energy: energy)
        }

        return spec
    }
}
