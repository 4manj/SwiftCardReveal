import Testing
import simd
@testable import s_reveal

struct ParticleSystemTests {

    @Test
    func returnsRequestedCount() {
        let particles = ParticleSystem.makeInitialParticles(
            count: 1024, seed: 1, aspect: 0.5625
        )
        #expect(particles.count == 1024)
    }

    @Test
    func handlesZeroCount() {
        let particles = ParticleSystem.makeInitialParticles(
            count: 0, seed: 1, aspect: 1.0
        )
        #expect(particles.isEmpty)
    }

    @Test
    func deterministicForFixedSeed() {
        let a = ParticleSystem.makeInitialParticles(count: 128, seed: 42, aspect: 0.5625)
        let b = ParticleSystem.makeInitialParticles(count: 128, seed: 42, aspect: 0.5625)
        for (p, q) in zip(a, b) {
            #expect(p.position == q.position)
            #expect(p.velocity == q.velocity)
            #expect(p.size == q.size)
            #expect(p.hueOffset == q.hueOffset)
        }
    }

    @Test
    func differentSeedsProduceDifferentOutputs() {
        let a = ParticleSystem.makeInitialParticles(count: 128, seed: 1, aspect: 1.0)
        let b = ParticleSystem.makeInitialParticles(count: 128, seed: 2, aspect: 1.0)
        let anyDiff = zip(a, b).contains { $0.position != $1.position }
        #expect(anyDiff)
    }

    @Test
    func positionsCoverFullParticleField() {
        let aspect: Float = 0.5625
        let particles = ParticleSystem.makeInitialParticles(
            count: 4096, seed: 7, aspect: aspect
        )
        var buckets = Set<Int>()
        for p in particles {
            #expect(p.position.x >= -aspect)
            #expect(p.position.x <= aspect)
            #expect(p.position.y >= -1.05)
            #expect(p.position.y <= 1.05)
            let xBucket = min(2, max(0, Int(((p.position.x + aspect) / (2 * aspect)) * 3)))
            let yBucket = min(2, max(0, Int(((p.position.y + 1.05) / 2.1) * 3)))
            buckets.insert(yBucket * 3 + xBucket)
        }
        #expect(buckets.count == 9)
    }

    @Test
    func sizeWithinConfiguredRange() {
        var params = SimulationParameters()
        params.pointSizeRange = 3.0 ... 5.0
        let particles = ParticleSystem.makeInitialParticles(
            count: 1024, seed: 9, aspect: 1.0, params: params
        )
        for p in particles {
            #expect(p.size >= 3.0)
            #expect(p.size <= 5.0)
        }
    }

    @Test
    func hueOffsetIsNormalized() {
        let particles = ParticleSystem.makeInitialParticles(count: 1024, seed: 11, aspect: 1.0)
        for p in particles {
            #expect(p.hueOffset >= 0.0)
            #expect(p.hueOffset <= 1.0)
        }
    }

    @Test
    func particleStrideMatchesShader() {
        // The Metal `Particle` struct in Common.h is 32 bytes.
        // If this ever drifts, the GPU reads garbage.
        #expect(MemoryLayout<Particle>.stride == 32)
    }

    @Test
    func frameUniformsStrideMatchesShader() {
        let stride = MemoryLayout<FrameUniforms>.stride
        #expect(stride == 80)
    }

    @Test
    func cloudUniformsStrideMatchesShader() {
        #expect(MemoryLayout<CloudUniforms>.stride == 20)
    }
}
