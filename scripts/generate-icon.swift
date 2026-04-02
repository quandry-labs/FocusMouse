#!/usr/bin/env swift

import Cocoa
import CoreGraphics

// MARK: - Icon Size Configuration

struct IconVariant {
    let name: String
    let pixels: Int
}

let macOSIconVariants: [IconVariant] = [
    IconVariant(name: "icon_16x16", pixels: 16),
    IconVariant(name: "icon_16x16@2x", pixels: 32),
    IconVariant(name: "icon_32x32", pixels: 32),
    IconVariant(name: "icon_32x32@2x", pixels: 64),
    IconVariant(name: "icon_128x128", pixels: 128),
    IconVariant(name: "icon_128x128@2x", pixels: 256),
    IconVariant(name: "icon_256x256", pixels: 256),
    IconVariant(name: "icon_256x256@2x", pixels: 512),
    IconVariant(name: "icon_512x512", pixels: 512),
    IconVariant(name: "icon_512x512@2x", pixels: 1024),
]

// MARK: - Drawing Constants

/// All layout values are expressed as fractions of the icon size,
/// so the icon scales cleanly to any resolution.
enum Layout {
    static let backgroundInset: CGFloat = 0.04
    static let cornerRadius: CGFloat = 0.22
    static let borderWidth: CGFloat = 0.01

    static let cursorOffsetX: CGFloat = 0.42
    static let cursorOffsetY: CGFloat = 0.50
    static let cursorHeight: CGFloat = 0.43
    static let cursorWidth: CGFloat = 0.29
    static let cursorBorderWidth: CGFloat = 1.5 / 512.0

    static let motionLineStartX: CGFloat = 0.55   // relative to cursor right edge
    static let motionLineSpacing: CGFloat = 28.0 / 512.0
    static let motionLineBaseLength: CGFloat = 50.0 / 512.0
    static let motionLineShrink: CGFloat = 8.0 / 512.0
    static let motionLineWidth: CGFloat = 4.0 / 512.0
    static let motionLineCount = 3

    static let glowRadius: CGFloat = 6.0 / 512.0
    static let shadowOffsetX: CGFloat = 2.0 / 512.0
    static let shadowOffsetY: CGFloat = -3.0 / 512.0
    static let shadowBlur: CGFloat = 8.0 / 512.0
}

enum Colors {
    static let bgGradientTop = CGColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)
    static let bgGradientBottom = CGColor(red: 0.15, green: 0.12, blue: 0.25, alpha: 1.0)
    static let border = CGColor(red: 0.3, green: 0.3, blue: 0.45, alpha: 0.5)
    static let cursorFill = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)
    static let cursorStroke = CGColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 0.6)
    static let shadow = CGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
    static let motionLine = (r: 0.2 as CGFloat, g: 0.85 as CGFloat, b: 0.9 as CGFloat)
    static let glow = (r: 0.3 as CGFloat, g: 0.9 as CGFloat, b: 1.0 as CGFloat)
}

// MARK: - Drawing Functions

func drawBackground(_ ctx: CGContext, size: CGFloat) {
    let inset = size * Layout.backgroundInset
    let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
    let radius = size * Layout.cornerRadius
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Gradient fill
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [Colors.bgGradientTop, Colors.bgGradientBottom] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])
    ctx.restoreGState()

    // Border
    ctx.addPath(path)
    ctx.setStrokeColor(Colors.border)
    ctx.setLineWidth(size * Layout.borderWidth)
    ctx.strokePath()
}

/// Build the cursor arrow path. Returns (path, tipPoint) for glow placement.
func cursorGeometry(size: CGFloat) -> (CGPath, CGPoint) {
    let cx = size * Layout.cursorOffsetX
    let cy = size * Layout.cursorOffsetY
    let h = size * Layout.cursorHeight
    let w = size * Layout.cursorWidth

    let tipX = cx - w * 0.15
    let tipY = cy + h * 0.45

    let path = CGMutablePath()
    path.move(to: CGPoint(x: tipX, y: tipY))
    path.addLine(to: CGPoint(x: tipX, y: tipY - h))
    path.addLine(to: CGPoint(x: tipX + w * 0.85, y: tipY - h * 0.62))
    path.addLine(to: CGPoint(x: tipX + w * 0.48, y: tipY - h * 0.55))
    path.addLine(to: CGPoint(x: tipX + w * 0.78, y: tipY - h * 0.15))
    path.addLine(to: CGPoint(x: tipX + w * 0.55, y: tipY - h * 0.05))
    path.addLine(to: CGPoint(x: tipX + w * 0.28, y: tipY - h * 0.42))
    path.closeSubpath()

    return (path, CGPoint(x: tipX, y: tipY))
}

func drawCursor(_ ctx: CGContext, size: CGFloat) -> CGPoint {
    let (path, tip) = cursorGeometry(size: size)

    // Shadow + fill
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: size * Layout.shadowOffsetX, height: size * Layout.shadowOffsetY),
                  blur: size * Layout.shadowBlur,
                  color: Colors.shadow)
    ctx.addPath(path)
    ctx.setFillColor(Colors.cursorFill)
    ctx.fillPath()
    ctx.restoreGState()

    // Border
    ctx.addPath(path)
    ctx.setStrokeColor(Colors.cursorStroke)
    ctx.setLineWidth(size * Layout.cursorBorderWidth)
    ctx.strokePath()

    return tip
}

func drawMotionLines(_ ctx: CGContext, size: CGFloat) {
    let cx = size * Layout.cursorOffsetX
    let cy = size * Layout.cursorOffsetY
    let w = size * Layout.cursorWidth
    let h = size * Layout.cursorHeight

    let baseX = cx + w * Layout.motionLineStartX
    let baseY = cy + h * 0.05

    for i in 0..<Layout.motionLineCount {
        let fi = CGFloat(i)
        let offset = fi * size * Layout.motionLineSpacing
        let lineLength = size * (Layout.motionLineBaseLength - fi * Layout.motionLineShrink)
        let alpha = 0.8 - fi * 0.2

        ctx.setStrokeColor(CGColor(red: Colors.motionLine.r, green: Colors.motionLine.g,
                                   blue: Colors.motionLine.b, alpha: alpha))
        ctx.setLineWidth(size * Layout.motionLineWidth)
        ctx.setLineCap(.round)

        let startY = baseY - lineLength / 2 + offset * 0.3
        ctx.move(to: CGPoint(x: baseX + offset, y: startY))
        ctx.addLine(to: CGPoint(x: baseX + offset, y: startY + lineLength))
        ctx.strokePath()
    }
}

func drawGlow(_ ctx: CGContext, at center: CGPoint, size: CGFloat) {
    let radius = size * Layout.glowRadius
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: Colors.glow.r, green: Colors.glow.g, blue: Colors.glow.b, alpha: 0.6),
        CGColor(red: Colors.glow.r, green: Colors.glow.g, blue: Colors.glow.b, alpha: 0.0),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(gradient,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius,
                           options: [])
}

// MARK: - Icon Generation

func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    drawBackground(ctx, size: size)
    let cursorTip = drawCursor(ctx, size: size)
    drawMotionLines(ctx, size: size)
    drawGlow(ctx, at: cursorTip, size: size)

    image.unlockFocus()
    return image
}

// MARK: - PNG Export

func savePNG(image: NSImage, toPath path: String, pixelSize: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"])
    }

    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
               from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

let projectDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetDir = "\(projectDir)/Resources/AppIcon.iconset"

do {
    try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

    print("Generating icon variants...")
    let baseImage = generateIcon(size: 1024)

    for variant in macOSIconVariants {
        let path = "\(iconsetDir)/\(variant.name).png"
        try savePNG(image: baseImage, toPath: path, pixelSize: variant.pixels)
        print("  \(variant.name).png (\(variant.pixels)x\(variant.pixels))")
    }

    print("Done! Iconset at: \(iconsetDir)")
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
