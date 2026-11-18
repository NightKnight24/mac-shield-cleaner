import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/appicon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let rect = CGRect(x: 92, y: 92, width: 840, height: 840)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()

let colors = [
    CGColor(red: 0.07, green: 0.11, blue: 0.22, alpha: 1.0),
    CGColor(red: 0.04, green: 0.06, blue: 0.13, alpha: 1.0)
]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 932), end: CGPoint(x: 512, y: 92), options: [])

let glowColors = [
    CGColor(red: 0.08, green: 0.78, blue: 0.65, alpha: 0.35),
    CGColor(red: 0.08, green: 0.78, blue: 0.65, alpha: 0.0)
]
let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors as CFArray, locations: [0.0, 1.0])!
ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: 512, y: 540), startRadius: 20, endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
ctx.restoreGState()

ctx.setStrokeColor(CGColor(red: 0.25, green: 0.85, blue: 0.75, alpha: 0.45))
ctx.setLineWidth(10)
ctx.addPath(path)
ctx.strokePath()

let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 780))
shield.addLine(to: CGPoint(x: 720, y: 700))
shield.addCurve(to: CGPoint(x: 512, y: 240), control1: CGPoint(x: 720, y: 460), control2: CGPoint(x: 625, y: 315))
shield.addCurve(to: CGPoint(x: 304, y: 700), control1: CGPoint(x: 399, y: 315), control2: CGPoint(x: 304, y: 460))
shield.closeSubpath()

ctx.saveGState()
ctx.addPath(shield)
ctx.clip()
let sColors = [
    CGColor(red: 0.10, green: 0.85, blue: 0.68, alpha: 1.0),
    CGColor(red: 0.06, green: 0.48, blue: 0.85, alpha: 1.0)
]
let sGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sColors as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(sGrad, start: CGPoint(x: 320, y: 780), end: CGPoint(x: 700, y: 240), options: [])
ctx.restoreGState()

ctx.setStrokeColor(CGColor(red: 0.85, green: 0.98, blue: 1.0, alpha: 0.7))
ctx.setLineWidth(8)
ctx.addPath(shield)
ctx.strokePath()

let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 535, y: 650))
bolt.addLine(to: CGPoint(x: 445, y: 505))
bolt.addLine(to: CGPoint(x: 512, y: 505))
bolt.addLine(to: CGPoint(x: 485, y: 365))
bolt.addLine(to: CGPoint(x: 585, y: 525))
bolt.addLine(to: CGPoint(x: 518, y: 525))
bolt.closeSubpath()

ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.96))
ctx.addPath(bolt)
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
try! pngData.write(to: URL(fileURLWithPath: outPath))
