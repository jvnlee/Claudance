import AppKit

struct Animator {

    private(set) var phase: Double = 0
    private var speed: Double = 0
    private var energy: Double = 0

    mutating func update(_ snap: ActivitySnapshot, dt: Double) -> ClawdDrawSpec {
        let targetSpeed: Double
        let targetEnergy: Double

        switch snap.state {
        case .working:
            let a = snap.activity
            targetSpeed = 9 + a * 12
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

        return Self.pose(state: snap.state, phase: phase, energy: energy)
    }

    static let loopPhase = 4 * Double.pi

    static func pose(state: ClaudeActivity, phase: Double, energy: Double) -> ClawdDrawSpec {
        let bounce = abs(sin(phase))
        let s = (bounce - 0.5) * 2

        var spec = ClawdDrawSpec()

        switch state {
        case .rest:
            spec.frame = ClawdFrame.apart
            spec.closedEyes = true
            spec.alpha = 0.5

        case .idle:
            spec.frame = ClawdFrame.apart
            spec.bob = bounce * 1.0 * energy
            spec.leanRadians = 0.06 * sin(phase * 0.5)
            spec.scaleY = 1 + 0.04 * s
            spec.scaleX = 1 - 0.03 * s
            spec.alpha = 0.95

        case .waiting:
            spec.frame = ClawdFrame.apart
            spec.bob = bounce * 1.6
            spec.leanRadians = 0.10 * sin(phase)

        case .working:
            spec.frame = bounce < 0.5 ? ClawdFrame.together : ClawdFrame.apart
            spec.bob = bounce * 2.6 * energy
            spec.scaleY = 1 + 0.13 * energy * s
            spec.scaleX = 1 - 0.11 * energy * s
            spec.leanRadians = 0.16 * energy * sin(phase * 0.5)
        }

        return spec
    }
}
