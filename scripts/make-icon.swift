#!/usr/bin/env swift
import AppKit
import Foundation

// Generates the Bucket Manager app icon at every macOS iconset size.
// Source of truth: assets/AppIcon.svg. Run from the repository root:
//   swift scripts/make-icon.swift

let output = URL(fileURLWithPath: "assets/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func render(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "BucketManagerIcon", code: 1)
    }

    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let u = CGFloat(pixels)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: u, height: u).fill()

    let contentInsetRatio: CGFloat = 100.0 / 1024.0
    let contentInset = u * contentInsetRatio
    let contentScale = 1 - contentInsetRatio * 2
    context.cgContext.translateBy(x: contentInset, y: contentInset)
    context.cgContext.scaleBy(x: contentScale, y: contentScale)

    let bounds = NSRect(x: 0, y: 0, width: u, height: u)
    let squircle = NSBezierPath(
        roundedRect: bounds,
        xRadius: u * 0.225,
        yRadius: u * 0.225
    )

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let blue = NSGradient(colors: [
        color(0x1D7CF2),
        color(0x0A4EAE),
        color(0x08347A)
    ])!
    blue.draw(in: bounds, angle: -90)

    // A restrained top sheen keeps the icon dimensional without looking glossy.
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.15),
        NSColor.white.withAlphaComponent(0.0)
    ])!
    sheen.draw(in: NSRect(x: 0, y: u * 0.50, width: u, height: u * 0.50), angle: -90)

    // Bucket handle: a single, clean arch.
    let handle = NSBezierPath()
    handle.lineWidth = u * 0.052
    handle.lineCapStyle = .round
    handle.lineJoinStyle = .round
    handle.move(to: NSPoint(x: u * 0.305, y: u * 0.625))
    handle.curve(
        to: NSPoint(x: u * 0.695, y: u * 0.625),
        controlPoint1: NSPoint(x: u * 0.305, y: u * 0.845),
        controlPoint2: NSPoint(x: u * 0.695, y: u * 0.845)
    )
    color(0xF7FAFF).setStroke()
    handle.stroke()

    // Tapered bucket body with a softly rounded base.
    let body = NSBezierPath()
    body.move(to: NSPoint(x: u * 0.255, y: u * 0.625))
    body.line(to: NSPoint(x: u * 0.330, y: u * 0.300))
    body.curve(
        to: NSPoint(x: u * 0.670, y: u * 0.300),
        controlPoint1: NSPoint(x: u * 0.335, y: u * 0.245),
        controlPoint2: NSPoint(x: u * 0.665, y: u * 0.245)
    )
    body.line(to: NSPoint(x: u * 0.745, y: u * 0.625))
    body.close()
    color(0xF7FAFF).setFill()
    body.fill()

    // Rim and the open interior.
    let rim = NSBezierPath(ovalIn: NSRect(
        x: u * 0.255, y: u * 0.575, width: u * 0.490, height: u * 0.105
    ))
    color(0xF7FAFF).setFill()
    rim.fill()

    let opening = NSBezierPath(ovalIn: NSRect(
        x: u * 0.300, y: u * 0.595, width: u * 0.400, height: u * 0.070
    ))
    color(0x0A367F).setFill()
    opening.fill()

    // Fine inner edge on the rim for definition at large sizes.
    if pixels >= 128 {
        let edge = NSBezierPath(ovalIn: NSRect(
            x: u * 0.262, y: u * 0.580, width: u * 0.476, height: u * 0.096
        ))
        edge.lineWidth = max(1, u * 0.0035)
        color(0xFFFFFF, alpha: 0.28).setStroke()
        edge.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BucketManagerIcon", code: 2)
    }
    return data
}

for entry in sizes {
    let data = try render(pixels: entry.pixels)
    try data.write(to: output.appendingPathComponent(entry.name), options: .atomic)
}

print("Generated \(sizes.count) icon files in \(output.path)")
