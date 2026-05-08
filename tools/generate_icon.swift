#!/usr/bin/env swift
//
// generate_icon.swift
//
// Renders Overleaf Desktop's app icon at every size macOS expects, packs
// them into AppIcon.iconset/, and bundles into AppIcon.icns via iconutil.
//
// Run:  swift tools/generate_icon.swift
// Output: tools/AppIcon.iconset/, Sources/OverleafDesktop/Resources/AppIcon.icns
//
// Design: indigo→violet squircle gradient + white rounded "page" with three
// subtle text marks + a bold serif "λ" centered on it. Reads as "research
// document" without copying any existing logo.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Configuration

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let toolsDir = scriptURL.deletingLastPathComponent()
let repoRoot = toolsDir.deletingLastPathComponent()
let iconsetDir = toolsDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsPath = repoRoot
    .appendingPathComponent("Sources/OverleafDesktop/Resources/AppIcon.icns")

let fm = FileManager.default
if fm.fileExists(atPath: iconsetDir.path) {
    try fm.removeItem(at: iconsetDir)
}
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// macOS expects:  N×N (1x) AND N×N@2x for each base size.
struct Variant { let baseSize: Int; let scale: Int; var pixelSize: Int { baseSize * scale } }
let variants: [Variant] = [
    .init(baseSize: 16, scale: 1),
    .init(baseSize: 16, scale: 2),
    .init(baseSize: 32, scale: 1),
    .init(baseSize: 32, scale: 2),
    .init(baseSize: 128, scale: 1),
    .init(baseSize: 128, scale: 2),
    .init(baseSize: 256, scale: 1),
    .init(baseSize: 256, scale: 2),
    .init(baseSize: 512, scale: 1),
    .init(baseSize: 512, scale: 2),
]

// MARK: - Drawing

func renderIcon(pixelSize px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Failed to create CGContext") }

    // Flip so y=0 is top — easier to reason about.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // ----- Background squircle with vertical gradient -----
    let cornerRadius = s * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(
        roundedRect: bgRect,
        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()

    let topColor = CGColor(srgbRed: 0.28, green: 0.24, blue: 0.86, alpha: 1.0)   // indigo
    let bottomColor = CGColor(srgbRed: 0.55, green: 0.34, blue: 0.96, alpha: 1.0) // violet
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: s),
        options: []
    )
    ctx.restoreGState()

    // ----- Document (white rounded rect) -----
    let docW = s * 0.56
    let docH = s * 0.66
    let docX = (s - docW) / 2
    let docY = (s - docH) / 2 - s * 0.01    // very slightly above center
    let docCorner = s * 0.07
    let docRect = CGRect(x: docX, y: docY, width: docW, height: docH)
    let docPath = CGPath(
        roundedRect: docRect,
        cornerWidth: docCorner, cornerHeight: docCorner, transform: nil
    )

    // Soft drop shadow on the document — only for sizes where it's visible.
    if px >= 64 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: s * 0.012),
            blur: s * 0.030,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22)
        )
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(docPath); ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(docPath); ctx.fillPath()
    }

    // ----- "Text" marks on the document (top portion) — only if there's room -----
    if px >= 32 {
        let lineColor = CGColor(srgbRed: 0.86, green: 0.86, blue: 0.90, alpha: 1.0)
        ctx.setFillColor(lineColor)
        let marginX = s * 0.05
        let lineH = max(1.0, s * 0.018)
        let lineSpacing = s * 0.055
        let lineYStart = docY + s * 0.06
        let lineWidths: [CGFloat] = [0.42, 0.36, 0.32]
        for (i, w) in lineWidths.enumerated() {
            let r = CGRect(
                x: docX + marginX,
                y: lineYStart + CGFloat(i) * lineSpacing,
                width: docW * w,
                height: lineH
            )
            ctx.fill(r)
        }
    }

    // ----- Lambda character, centered, indigo on white -----
    drawLambda(in: ctx, canvasSize: s, docRect: docRect)

    // Output PNG
    guard let cgImage = ctx.makeImage() else { fatalError("Failed to render image") }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    return png
}

func drawLambda(in ctx: CGContext, canvasSize s: CGFloat, docRect: CGRect) {
    // Draw a lambda using NSAttributedString into a separate flipped context,
    // then composite. We want it visually centered on the document.
    let fontSize = s * 0.50
    let font = NSFont(name: "Times-Bold", size: fontSize)
        ?? NSFont(name: "TimesNewRomanPS-BoldMT", size: fontSize)
        ?? NSFont.boldSystemFont(ofSize: fontSize)
    let textColor = NSColor(srgbRed: 0.28, green: 0.24, blue: 0.86, alpha: 1.0)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
    ]
    let attr = NSAttributedString(string: "λ", attributes: attrs)
    let line = CTLineCreateWithAttributedString(attr)

    // Use ascent/descent to vertically center the visual glyph rather than the
    // typographic bounding box (which has lots of dead descender space).
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let glyphHeight = ascent + descent
    let textX = docRect.midX - CGFloat(advance) / 2
    let textY = docRect.midY - glyphHeight / 2 + descent + s * 0.02

    // We're in flipped coords (origin top-left). Flip back locally to draw text.
    ctx.saveGState()
    ctx.translateBy(x: textX, y: textY + ascent)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Run

print("→ Rendering \(variants.count) icon variants")
for v in variants {
    let png = renderIcon(pixelSize: v.pixelSize)
    let suffix = v.scale == 1 ? "" : "@\(v.scale)x"
    let name = "icon_\(v.baseSize)x\(v.baseSize)\(suffix).png"
    let url = iconsetDir.appendingPathComponent(name)
    try png.write(to: url)
    print("  • \(name) (\(v.pixelSize)px)")
}

print("→ Running iconutil")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", icnsPath.path, iconsetDir.path]
let outPipe = Pipe(); let errPipe = Pipe()
proc.standardOutput = outPipe; proc.standardError = errPipe
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    FileHandle.standardError.write("iconutil failed:\n\(err)".data(using: .utf8)!)
    exit(Int32(proc.terminationStatus))
}

print("✓ Wrote \(icnsPath.path)")

// Also refresh the standalone PNG copies in assets/ so README / social
// embeds stay in sync with the icon source.
let assetsDir = repoRoot.appendingPathComponent("assets", isDirectory: true)
try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
let copies: [(String, String)] = [
    ("icon_512x512@2x.png", "logo.png"),
    ("icon_256x256.png",    "logo-256.png"),
]
for (src, dst) in copies {
    let srcURL = iconsetDir.appendingPathComponent(src)
    let dstURL = assetsDir.appendingPathComponent(dst)
    if fm.fileExists(atPath: dstURL.path) {
        try? fm.removeItem(at: dstURL)
    }
    try fm.copyItem(at: srcURL, to: dstURL)
    print("  • assets/\(dst) (from \(src))")
}
