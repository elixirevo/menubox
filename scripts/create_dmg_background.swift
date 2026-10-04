// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: create_dmg_background.swift <output.png> [app-name]\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 660
let height = 420
let scale = 2
let pixelsWide = width * scale
let pixelsHigh = height * scale

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelsWide,
    pixelsHigh: pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Unable to create bitmap image\n", stderr)
    exit(1)
}

bitmap.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let rect = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.985, alpha: 1.0).setFill()
rect.fill()

let panelRect = NSRect(x: 28, y: 28, width: width - 56, height: height - 56)
let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 28, yRadius: 28)
NSColor(calibratedWhite: 1.0, alpha: 0.72).setFill()
panelPath.fill()
NSColor(calibratedRed: 0.72, green: 0.77, blue: 0.86, alpha: 0.45).setStroke()
panelPath.lineWidth = 1
panelPath.stroke()

let arrowY: CGFloat = CGFloat(height) / 2 + 4
let arrowStart = NSPoint(x: 262, y: arrowY)
let arrowEnd = NSPoint(x: 398, y: arrowY)
let arrowColor = NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.78, alpha: 0.72)

arrowColor.setStroke()
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 8
arrowPath.lineCapStyle = .round
arrowPath.move(to: arrowStart)
arrowPath.line(to: arrowEnd)
arrowPath.stroke()

arrowColor.setFill()
let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: arrowEnd.x + 2, y: arrowEnd.y))
arrowHead.line(to: NSPoint(x: arrowEnd.x - 24, y: arrowEnd.y + 18))
arrowHead.line(to: NSPoint(x: arrowEnd.x - 24, y: arrowEnd.y - 18))
arrowHead.close()
arrowHead.fill()

let dashColor = NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.78, alpha: 0.25)
dashColor.setStroke()
for x in stride(from: CGFloat(286), through: CGFloat(348), by: CGFloat(28)) {
    let dash = NSBezierPath()
    dash.lineWidth = 3
    dash.lineCapStyle = .round
    dash.move(to: NSPoint(x: x, y: arrowY - 28))
    dash.line(to: NSPoint(x: x + 14, y: arrowY - 28))
    dash.stroke()
}

let title = "Drag to Applications"
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.38, alpha: 0.78)
]
let titleSize = title.size(withAttributes: attributes)
title.draw(
    at: NSPoint(x: (CGFloat(width) - titleSize.width) / 2, y: 96),
    withAttributes: attributes
)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode PNG image\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try pngData.write(to: outputURL)
} catch {
    fputs("Unable to write background image: \(error)\n", stderr)
    exit(1)
}
