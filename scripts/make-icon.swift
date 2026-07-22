// SPDX-License-Identifier: GPL-2.0-or-later
// Generates Untracked's app icon as a set of PNGs into an .iconset dir.
// Concept: a red ECG/heartbeat pulse on a dark rounded square — references the
// heartbeat nag. Usage: swift make-icon.swift <output.iconset dir>
import AppKit
import CoreGraphics
import Foundation
import ImageIO

func render(size: Int, to path: String) {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    // Dark rounded-square background
    let inset = s * 0.04
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil))
    ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    ctx.fillPath()

    // Red heartbeat / ECG trace
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)) // #FF3B30
    ctx.setLineWidth(s * 0.058)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: s * x, y: s * y)
    }
    let trace = CGMutablePath()
    trace.move(to: pt(0.15, 0.50))
    trace.addLine(to: pt(0.36, 0.50))
    trace.addLine(to: pt(0.44, 0.70)) // spike up
    trace.addLine(to: pt(0.54, 0.28)) // down
    trace.addLine(to: pt(0.62, 0.57)) // small rebound
    trace.addLine(to: pt(0.85, 0.50))
    ctx.addPath(trace)
    ctx.strokePath()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
          ) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <iconset-dir>\n".utf8))
    exit(1)
}

let outDir = CommandLine.arguments[1]
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    render(size: size, to: "\(outDir)/\(name)")
}
