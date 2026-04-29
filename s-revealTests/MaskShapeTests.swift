import CoreGraphics
import Foundation
import Testing
@testable import s_reveal

struct MaskShapeTests {

    @Test
    func rasterizeProducesVisibleUpperRegion() {
        guard let image = MaskShape.rasterize(size: 64) else {
            Issue.record("MaskShape.rasterize(size:) returned nil")
            return
        }

        #expect(image.width == 64)
        #expect(image.height == 64)

        guard
            let provider = image.dataProvider,
            let data = provider.data
        else {
            Issue.record("Mask raster image has no provider data")
            return
        }

        let bytes = CFDataGetBytePtr(data)
        let bytesPerRow = image.bytesPerRow
        var foundUpperAlpha = false

        for y in 0 ..< max(1, image.height / 3) {
            for x in 0 ..< image.width {
                if bytes?[y * bytesPerRow + x] ?? 0 > 0 {
                    foundUpperAlpha = true
                    break
                }
            }
            if foundUpperAlpha { break }
        }

        #expect(foundUpperAlpha)
    }
}
