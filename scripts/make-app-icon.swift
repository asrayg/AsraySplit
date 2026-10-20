// Renders the original Asray Split app icon (1024×1024, opaque, no alpha channel).
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

let gradient = CGGradient(colorsSpace: space, colors: [rgb(0.04, 0.50, 0.34), rgb(0.43, 0.93, 0.71)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])

func receipt(_ f: CGRect, _ color: CGColor) {
    let teeth = 6, tooth = f.width / CGFloat(teeth)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: f.minX, y: f.maxY))
    ctx.addLine(to: CGPoint(x: f.maxX, y: f.maxY))
    ctx.addLine(to: CGPoint(x: f.maxX, y: f.minY))
    for i in stride(from: teeth, to: 0, by: -1) {
        ctx.addLine(to: CGPoint(x: f.minX + tooth * (CGFloat(i) - 0.5), y: f.minY + 34))
        ctx.addLine(to: CGPoint(x: f.minX + tooth * CGFloat(i - 1), y: f.minY))
    }
    ctx.closePath()
    ctx.setFillColor(color)
    ctx.fillPath()
}
receipt(CGRect(x: 290, y: 260, width: 380, height: 560), rgb(1, 1, 1, 0.45))
receipt(CGRect(x: 360, y: 200, width: 380, height: 560), rgb(0.98, 1, 0.99))
let ink = rgb(0.03, 0.2, 0.14)
ctx.setFillColor(ink)
for (i, width) in [260, 200, 230].enumerated() {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 420, y: 660 - i * 70, width: width, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
}
ctx.setStrokeColor(ink)
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [36, 26])
ctx.move(to: CGPoint(x: 550, y: 280)); ctx.addLine(to: CGPoint(x: 550, y: 470)); ctx.strokePath()

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
