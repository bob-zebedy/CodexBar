import AppKit
import QuartzCore
import Testing

struct AppearanceTransitionTests {
    @Test func unanchoredSnapshotsChooseIndependentOriginsWithinCentralRegion() throws {
        var origins = [CGPoint]()
        for _ in 0 ..< 64 {
            let view = AppearanceTransition.SnapshotView(image: NSImage(size: CGSize(width: 640, height: 240)))
            let mask = try #require(view.layer?.mask as? CAGradientLayer)
            let origin = mask.startPoint
            #expect(mask.type == .radial)
            #expect((0.1 ... 0.9).contains(origin.x))
            #expect((0.1 ... 0.9).contains(origin.y))
            view.setFrameSize(CGSize(width: 240, height: 640))
            view.layout()
            #expect(mask.startPoint == origin)
            origins.append(origin)
        }
        #expect(Set(origins.map(\.x)).count > 1)
        #expect(Set(origins.map(\.y)).count > 1)
    }

    @Test func manualAnchorHasPriorityOnlyInItsSourceWindow() {
        let frame = CGRect(x: 100, y: 200, width: 640, height: 240)
        let origin = CGPoint(x: 580, y: 380)
        let outside = CGPoint.zero
        let inside = CGPoint(x: 420, y: 320)
        #expect(AppearanceTransition.anchoredOrigin(from: origin, isSourceWindow: true, screenFrame: frame, mouseLocation: outside) == CGPoint(x: 0.75, y: 0.25))
        #expect(AppearanceTransition.anchoredOrigin(from: origin, isSourceWindow: true, screenFrame: frame, mouseLocation: inside) == CGPoint(x: 0.75, y: 0.25))
        #expect(AppearanceTransition.anchoredOrigin(from: origin, isSourceWindow: false, screenFrame: frame, mouseLocation: outside) == nil)
        #expect(AppearanceTransition.anchoredOrigin(from: origin, isSourceWindow: false, screenFrame: frame, mouseLocation: inside) == CGPoint(x: 0.5, y: 0.5))
        #expect(AppearanceTransition.anchoredOrigin(from: nil, isSourceWindow: false, screenFrame: frame, mouseLocation: outside) == nil)
    }

    @Test func pointerAnchorUsesPanelCoordinatesWithoutClampingToRandomRegion() {
        let frame = CGRect(x: -900, y: -400, width: 640, height: 240)
        let inside = CGPoint(x: -884, y: -172)
        #expect(AppearanceTransition.anchoredOrigin(from: nil, isSourceWindow: false, screenFrame: frame, mouseLocation: inside) == CGPoint(x: 0.025, y: 0.05))
        for outside in [CGPoint(x: -901, y: -280), CGPoint(x: -259, y: -280), CGPoint(x: -580, y: -401), CGPoint(x: -580, y: -159)] {
            #expect(AppearanceTransition.anchoredOrigin(from: nil, isSourceWindow: false, screenFrame: frame, mouseLocation: outside) == nil)
        }
    }

    @Test func manualRevealHasEqualHorizontalAndVerticalRadiiAfterResizing() throws {
        let view = AppearanceTransition.SnapshotView(
            image: NSImage(size: CGSize(width: 640, height: 240)),
            origin: CGPoint(x: 0.75, y: 0.5)
        )
        for size in [CGSize(width: 640, height: 240), CGSize(width: 240, height: 640)] {
            view.setFrameSize(size)
            view.layout()
            let bitmap = try renderMask(of: view, locations: [0.09, 0.11])
            let centerX = Int(size.width * 0.75)
            let centerY = Int(size.height * 0.5)
            for offset in [-25, 0, 25] {
                #expect(try alpha(in: bitmap, x: centerX + offset, y: centerY) < 0.01)
                #expect(try alpha(in: bitmap, x: centerX, y: centerY + offset) < 0.01)
            }
            #expect(try alpha(in: bitmap, x: centerX - 58, y: centerY) > 0.99)
            #expect(try alpha(in: bitmap, x: centerX, y: centerY - 58) > 0.99)
        }
    }

    @Test(arguments: [CGPoint(x: 0.8, y: 0.2), CGPoint(x: -0.5, y: 1.5)])
    func radialRevealCoversAllCornersIncludingOriginsOutsideWindow(_ origin: CGPoint) throws {
        let view = AppearanceTransition.SnapshotView(
            image: NSImage(size: CGSize(width: 640, height: 240)),
            origin: origin
        )
        let bitmap = try renderMask(of: view, locations: [1, 1])
        for x in [0, 639] {
            for y in [0, 239] {
                #expect(try alpha(in: bitmap, x: x, y: y) < 0.01)
            }
        }
    }

    @Test func interruptedDrawerMovementResetsWithoutRemovingRadialReveal() throws {
        let view = AppearanceTransition.SnapshotView(image: NSImage(size: CGSize(width: 320, height: 240)))
        let layer = try #require(view.layer)
        let mask = try #require(layer.mask as? CAGradientLayer)
        let reveal = CABasicAnimation(keyPath: "locations")
        reveal.fromValue = [0, 0]
        reveal.toValue = [1, 1]
        reveal.duration = 0.5
        mask.add(reveal, forKey: "testReveal")

        for (start, end, duration) in [(0.0, -320.0, 0.12), (-160.0, 0.0, 0.18)] {
            let animation = CABasicAnimation(keyPath: "transform")
            let from = CATransform3DMakeTranslation(start, 0, 0)
            let to = CATransform3DMakeTranslation(end, 0, 0)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            view.animateTranslation(animation, to: to)

            let keys = try #require(layer.animationKeys())
            #expect(keys.count == 1)
            let key = try #require(keys.first)
            let copied = try #require(layer.animation(forKey: key) as? CABasicAnimation)
            #expect(copied.duration == duration)
            #expect(try CATransform3DEqualToTransform(#require(copied.fromValue as? NSValue).caTransform3DValue, from))
            #expect(try CATransform3DEqualToTransform(#require(copied.toValue as? NSValue).caTransform3DValue, to))
            #expect(CATransform3DEqualToTransform(layer.transform, to))
        }

        view.setTranslation(CATransform3DIdentity)
        #expect(layer.animationKeys()?.isEmpty != false)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(mask.animation(forKey: "testReveal") != nil)
    }

    private func renderMask(of view: NSView, locations: [NSNumber]) throws -> NSBitmapImageRep {
        let mask = try #require(view.layer?.mask as? CAGradientLayer)
        mask.locations = locations
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.clear(view.bounds)
        context.cgContext.translateBy(x: 0, y: view.bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        mask.render(in: context.cgContext)
        return bitmap
    }

    private func alpha(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
    }
}
