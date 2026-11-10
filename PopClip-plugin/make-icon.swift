#!/usr/bin/env swift
//
// Renders the PopClip action icon (512×512 PNG, transparent background).
// Run from anywhere: `swift PopClip-plugin/make-icon.swift`.
//
// PopClip wants a monochrome shape on a transparent background; it tints
// the file icon to match the PopClip bar. The SF Symbol "translate" is
// wide (two bubbles side by side), so it only fills about half of the
// square button's height. This draws a squarer version instead: two
// overlapping speech bubbles on a diagonal, one with "A" and one with "文".
//
// The bubbles are solid black with knocked-out letters, which pop at the
// ~22 px size PopClip renders. A transparent gap is erased around the
// front bubble so the two shapes stay legible where they overlap.

import AppKit

let pixelSize = 512
let canvas = CGFloat(pixelSize)

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
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Could not create the bitmap context")
}
rep.size = NSSize(width: pixelSize, height: pixelSize)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

// The composition is 488×460; nudge it up 26 px so the top and bottom
// margins match (the front bubble's tail otherwise touches the edge).
let centerVertically = NSAffineTransform()
centerVertically.translateX(by: 0, yBy: 26)
centerVertically.concat()

struct Bubble {
    let body: NSBezierPath
    let tail: NSBezierPath
}

func bubble(rect: NSRect, corner: CGFloat, tail points: [NSPoint]) -> Bubble {
    let body = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let tail = NSBezierPath()
    tail.move(to: points[0])
    tail.line(to: points[1])
    tail.line(to: points[2])
    tail.close()
    return Bubble(body: body, tail: tail)
}

func fill(_ bubble: Bubble) {
    NSColor.black.setFill()
    bubble.body.fill()
    bubble.tail.fill()
}

/// Erases a transparent outline around the front bubble so the two
/// overlapping shapes don't merge into one blob.
func eraseGap(around bubble: Bubble, width: CGFloat) {
    guard let context = NSGraphicsContext.current else { return }
    context.compositingOperation = .copy
    NSColor.clear.setStroke()
    for path in [bubble.body, bubble.tail] {
        path.lineWidth = width
        path.stroke()
    }
    context.compositingOperation = .sourceOver
}

func punch(_ text: String, centeredAt center: NSPoint, font: NSFont) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
    let string = text as NSString
    let textSize = string.size(withAttributes: attributes)
    let drawRect = NSRect(
        x: center.x - textSize.width / 2,
        y: center.y - textSize.height / 2,
        width: textSize.width,
        height: textSize.height
    )
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    string.draw(in: drawRect, withAttributes: attributes)
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}

// Back bubble (top right) — "文".
let back = bubble(
    rect: NSRect(x: 230, y: 210, width: 270, height: 250),
    corner: 68,
    tail: [
        NSPoint(x: 400, y: 210),
        NSPoint(x: 458, y: 210),
        NSPoint(x: 438, y: 146),
    ]
)
fill(back)
punch("文", centeredAt: NSPoint(x: 372, y: 352), font: .systemFont(ofSize: 150, weight: .semibold))

// Front bubble (bottom left) — "A". Erase a gap around it first so the
// back bubble's outline stays visible where they overlap.
let front = bubble(
    rect: NSRect(x: 12, y: 52, width: 270, height: 250),
    corner: 68,
    tail: [
        NSPoint(x: 58, y: 52),
        NSPoint(x: 116, y: 52),
        NSPoint(x: 68, y: 0),
    ]
)
eraseGap(around: front, width: 18)
fill(front)
punch("A", centeredAt: NSPoint(x: 158, y: 190), font: .systemFont(ofSize: 175, weight: .bold))

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}

let output = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("atst.popclipext/icon.png")
try png.write(to: output)
print("Wrote \(output.path)")
