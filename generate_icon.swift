#!/usr/bin/env swift
import AppKit
import CoreGraphics

let brandBlue = NSColor(red: 0x00/255.0, green: 0x40/255.0, blue: 0x80/255.0, alpha: 1.0)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let cx = s / 2
    let cy = s / 2

    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    brandBlue.setFill()
    bgPath.fill()

    let gradSpace = CGColorSpaceCreateDeviceRGB()
    let depthColors = [
        NSColor(white: 1.0, alpha: 0.08).cgColor,
        NSColor(white: 0.0, alpha: 0.10).cgColor,
    ] as CFArray
    if let depth = CGGradient(colorsSpace: gradSpace, colors: depthColors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(bgPath.cgPath)
        ctx.clip()
        ctx.drawRadialGradient(depth,
            startCenter: CGPoint(x: cx, y: cy + s * 0.12),
            startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy),
            endRadius: s * 0.55,
            options: [])
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    let strong = NSColor(white: 1.0, alpha: 0.85)
    let soft   = NSColor(white: 1.0, alpha: 0.45)
    let stroke = s * 0.018
    let thin   = s * 0.010

    // ── Eye almond ──
    let halfW = s * 0.30
    let halfH = s * 0.16

    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: cx - halfW, y: cy))
    eye.addQuadCurve(to: CGPoint(x: cx + halfW, y: cy),
                     control: CGPoint(x: cx, y: cy + halfH * 1.7))
    eye.addQuadCurve(to: CGPoint(x: cx - halfW, y: cy),
                     control: CGPoint(x: cx, y: cy - halfH * 1.7))
    eye.closeSubpath()

    ctx.setStrokeColor(strong.cgColor)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(eye)
    ctx.strokePath()

    // ── Iris ──
    let irisR = s * 0.115
    let irisRect = CGRect(x: cx - irisR, y: cy - irisR, width: irisR * 2, height: irisR * 2)
    ctx.setStrokeColor(strong.cgColor)
    ctx.setLineWidth(stroke)
    ctx.strokeEllipse(in: irisRect)

    // Inner thin ring for depth
    let innerR = irisR * 0.62
    ctx.setStrokeColor(soft.cgColor)
    ctx.setLineWidth(thin)
    ctx.strokeEllipse(in: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))

    // ── Pupil — filled solid ──
    let pupilR = s * 0.038
    ctx.setFillColor(strong.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - pupilR, y: cy - pupilR, width: pupilR * 2, height: pupilR * 2))

    // ── Crosshair-style tick marks beyond the eye ──
    // Subtle directional ticks that say "scanning / lookout" without being literal.
    ctx.setStrokeColor(soft.cgColor)
    ctx.setLineWidth(thin)
    ctx.setLineCap(.round)

    let tickInner = halfW + s * 0.04
    let tickOuter = tickInner + s * 0.05

    // Left
    ctx.move(to: CGPoint(x: cx - tickInner, y: cy))
    ctx.addLine(to: CGPoint(x: cx - tickOuter, y: cy))
    // Right
    ctx.move(to: CGPoint(x: cx + tickInner, y: cy))
    ctx.addLine(to: CGPoint(x: cx + tickOuter, y: cy))

    // Top — shorter
    let vTickInner = halfH * 1.7 + s * 0.03
    let vTickOuter = vTickInner + s * 0.04
    ctx.move(to: CGPoint(x: cx, y: cy + vTickInner))
    ctx.addLine(to: CGPoint(x: cx, y: cy + vTickOuter))
    // Bottom
    ctx.move(to: CGPoint(x: cx, y: cy - vTickInner))
    ctx.addLine(to: CGPoint(x: cx, y: cy - vTickOuter))
    ctx.strokePath()

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        let points = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        for i in 0..<elementCount {
            let element = self.element(at: i, associatedPoints: points)
            switch element {
            case .moveTo:    path.move(to: points[0])
            case .lineTo:    path.addLine(to: points[0])
            case .curveTo:   path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let destDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let sizes: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png",256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png",512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png",1024),
]

for (filename, pixels) in sizes {
    let image = drawIcon(size: CGFloat(pixels))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    let url = URL(fileURLWithPath: destDir).appendingPathComponent(filename)
    try! png.write(to: url)
}
