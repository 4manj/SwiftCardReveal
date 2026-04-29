import Testing
import CoreGraphics
@testable import s_reveal

struct CoordinateConversionTests {

    @Test
    func centerOfViewMapsToOrigin() {
        let p = CoordinateSpace.tapToParticleSpace(
            viewLocation: CGPoint(x: 100, y: 200),
            viewSize: CGSize(width: 200, height: 400),
            aspect: 0.5
        )
        #expect(abs(p.x) < 1e-5)
        #expect(abs(p.y) < 1e-5)
    }

    @Test
    func topLeftMapsToNegativeXPositiveY() {
        // View has top-left origin; Y is flipped in particle space.
        let p = CoordinateSpace.tapToParticleSpace(
            viewLocation: .zero,
            viewSize: CGSize(width: 200, height: 400),
            aspect: 0.5
        )
        #expect(p.x < 0)
        #expect(p.y > 0)
    }

    @Test
    func bottomRightMapsToPositiveXNegativeY() {
        let p = CoordinateSpace.tapToParticleSpace(
            viewLocation: CGPoint(x: 200, y: 400),
            viewSize: CGSize(width: 200, height: 400),
            aspect: 0.5
        )
        #expect(p.x > 0)
        #expect(p.y < 0)
    }

    @Test
    func xScalesByAspect() {
        let aspect: Float = 0.6
        let p = CoordinateSpace.tapToParticleSpace(
            viewLocation: CGPoint(x: 200, y: 200),
            viewSize: CGSize(width: 200, height: 400),
            aspect: aspect
        )
        // x normalized to +1, then multiplied by aspect.
        #expect(abs(p.x - aspect) < 1e-5)
    }

    @Test
    func zeroSizedViewReturnsZero() {
        let p = CoordinateSpace.tapToParticleSpace(
            viewLocation: CGPoint(x: 50, y: 50),
            viewSize: .zero,
            aspect: 0.5
        )
        #expect(p == .zero)
    }

    @Test
    func dtClampedAfterLongStall() {
        // Simulate a 1-second stall — the renderer should clamp to its max.
        let dt = FrameTiming.clampedDt(now: 100.0, last: 99.0)
        #expect(dt == FrameTiming.maxDt)
    }

    @Test
    func dtFallsThroughWhenSmall() {
        let dt = FrameTiming.clampedDt(now: 100.0, last: 99.984)
        #expect(abs(dt - 0.016) < 1e-3)
    }

    @Test
    func dtNilLastDefaultsTo60Hz() {
        let dt = FrameTiming.clampedDt(now: 100.0, last: nil)
        #expect(abs(dt - (1.0 / 60.0)) < 1e-6)
    }
}
