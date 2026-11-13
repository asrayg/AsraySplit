// Renders the AsraySplit app icon (1024×1024, opaque, no alpha channel).
// Usage: swift scripts/make-app-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// Deep indigo-to-violet backdrop reads clearly in both light and dark home screens.
let background = CGGradient(
    colorsSpace: space,
    colors: [rgb(0.07, 0.09, 0.24), rgb(0.25, 0.16, 0.62), rgb(0.47, 0.25, 0.86)] as CFArray,
    locations: [0, 0.58, 1]
)!
ctx.setFillColor(rgb(0.07, 0.09, 0.24))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.drawLinearGradient(background, start: CGPoint(x: 110, y: 950), end: CGPoint(x: 930, y: 80),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// A subtle halo gives the mark depth without relying on details that disappear at small sizes.
let halo = CGGradient(
    colorsSpace: space,
    colors: [rgb(0.53, 0.96, 0.77, 0.28), rgb(0.53, 0.96, 0.77, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 512, y: 512), startRadius: 30,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 470, options: [])

// The monogram combines an S-shaped shared path with two endpoints: two people, one fair split.
ctx.setStrokeColor(rgb(0.96, 1.0, 0.98))
ctx.setLineWidth(126)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: 703, y: 292))
ctx.addCurve(to: CGPoint(x: 321, y: 470), control1: CGPoint(x: 607, y: 205), control2: CGPoint(x: 329, y: 248))
ctx.addCurve(to: CGPoint(x: 703, y: 732), control1: CGPoint(x: 309, y: 658), control2: CGPoint(x: 610, y: 806))
ctx.strokePath()

// The mint split bar makes the purpose legible and forms the cross-stroke of the abstract S.
ctx.setStrokeColor(rgb(0.54, 0.98, 0.76))
ctx.setLineWidth(52)
ctx.setLineCap(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: 302, y: 512))
ctx.addLine(to: CGPoint(x: 722, y: 512))
ctx.strokePath()

ctx.setFillColor(rgb(0.54, 0.98, 0.76))
for point in [CGPoint(x: 254, y: 512), CGPoint(x: 770, y: 512)] {
    ctx.fillEllipse(in: CGRect(x: point.x - 34, y: point.y - 34, width: 68, height: 68))
}

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
