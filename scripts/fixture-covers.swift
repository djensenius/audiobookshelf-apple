#!/usr/bin/env swift  // Draws the fixture server's per-item covers (docs/testing/ui-tests.md#fixture-covers):
// `fixture-cover-<itemId>.png`, 600 × 600, in Audiobookshelf/Fixtures/Resources/ (or the
// directory given as the first argument). Original typographic designs, drawn with the system
// fonts at generation time, so the committed PNGs contain no third-party artwork or fonts.
// Flat colours only (no gradients), so the PNGs compress small.
//
//   mise run fixtures:covers      # or: swift scripts/fixture-covers.swift [directory]
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 600

struct Palette {
    let background: NSColor
    let shape: NSColor
    let accent: NSColor
    let text: NSColor
}

enum Motif {
    case arches, rings, lightning, lens, planet(moons: Int, rotation: CGFloat)
}

struct Cover {
    let id: String
    let title: String
    let author: String
    var series: String?
    let palette: Palette
    let motif: Motif
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let covers: [Cover] = [
    Cover(
        id: "li_pride", title: "Pride and Prejudice", author: "Jane Austen",
        palette: Palette(
            background: rgb(0xF4_E4_D7), shape: rgb(0xE2_B4_A6), accent: rgb(0x9C_3D_54), text: rgb(0x3B_1F_2B)),
        motif: .arches),
    Cover(
        id: "li_emma", title: "Emma", author: "Jane Austen",
        palette: Palette(
            background: rgb(0xDD_E8_D5), shape: rgb(0xA9_C6_A0), accent: rgb(0x4E_7A_5A), text: rgb(0x1F_36_2A)),
        motif: .rings),
    Cover(
        id: "li_frankenstein", title: "Frankenstein; or, The Modern Prometheus", author: "Mary Shelley",
        palette: Palette(
            background: rgb(0x16_2B_2A), shape: rgb(0x24_4A_45), accent: rgb(0xC8_E6_4A), text: rgb(0xF1_F5_E8)),
        motif: .lightning),
    Cover(
        id: "li_sherlock", title: "The Adventures of Sherlock Holmes", author: "Arthur Conan Doyle",
        palette: Palette(
            background: rgb(0x1B_23_3D), shape: rgb(0x2C_38_5E), accent: rgb(0xD9_A4_41), text: rgb(0xF6_EE_DC)),
        motif: .lens),
    Cover(
        id: "li_barsoom_1", title: "A Princess of Mars", author: "Edgar Rice Burroughs", series: "Barsoom · 1",
        palette: Palette(
            background: rgb(0x2A_12_1E), shape: rgb(0xC8_4B_2F), accent: rgb(0xF2_A3_5B), text: rgb(0xFB_EB_DC)),
        motif: .planet(moons: 1, rotation: 0)),
    Cover(
        id: "li_barsoom_2", title: "The Gods of Mars", author: "Edgar Rice Burroughs", series: "Barsoom · 2",
        palette: Palette(
            background: rgb(0x1E_14_38), shape: rgb(0xB0_3E_4C), accent: rgb(0xE8_8E_6A), text: rgb(0xF4_E9_F2)),
        motif: .planet(moons: 2, rotation: 0.6)),
    Cover(
        id: "li_barsoom_3", title: "The Warlord of Mars", author: "Edgar Rice Burroughs", series: "Barsoom · 3",
        palette: Palette(
            background: rgb(0x34_16_0E), shape: rgb(0xD9_6A_2B), accent: rgb(0xF7_C4_6C), text: rgb(0xFF_F2_E0)),
        motif: .planet(moons: 3, rotation: 0.3)),
]

func fill(_ context: CGContext, _ color: NSColor, _ path: CGPath) {
    context.setFillColor(color.cgColor)
    context.addPath(path)
    context.fillPath()
}

func stroke(_ context: CGContext, _ color: NSColor, width: CGFloat, _ path: CGPath) {
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.addPath(path)
    context.strokePath()
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(
        ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
        transform: nil)
}

/// The motif fills the top of the cover (y up, origin bottom left); the text sits below it.
func drawMotif(_ motif: Motif, _ palette: Palette, in context: CGContext) {
    switch motif {
    case .arches:
        for (index, width) in [CGFloat(420), 300, 180].enumerated() {
            let rect = CGRect(x: (side - width) / 2, y: 250, width: width, height: 300 - CGFloat(index) * 60)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - width / 2))
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.maxY - width / 2), radius: width / 2, startAngle: .pi,
                endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            fill(context, index == 1 ? palette.background : palette.shape, path)
        }
        fill(context, palette.accent, circle(CGPoint(x: side / 2, y: 330), 26))
    case .rings:
        for (index, radius) in [CGFloat(150), 110, 70, 30].enumerated() {
            fill(
                context, index.isMultiple(of: 2) ? palette.shape : palette.background,
                circle(CGPoint(x: side / 2, y: 410), radius))
        }
        fill(context, palette.accent, circle(CGPoint(x: side / 2, y: 410), 14))
        for x in stride(from: CGFloat(60), through: side - 60, by: 40) {
            fill(context, palette.shape, circle(CGPoint(x: x, y: 230), 5))
        }
    case .lightning:
        for x in stride(from: CGFloat(-200), to: side, by: 70) {
            let band = CGMutablePath()
            band.addLines(between: [
                CGPoint(x: x, y: 600), CGPoint(x: x + 35, y: 600), CGPoint(x: x + 235, y: 230),
                CGPoint(x: x + 200, y: 230),
            ])
            fill(context, palette.shape, band)
        }
        let bolt = CGMutablePath()
        bolt.addLines(between: [
            CGPoint(x: 330, y: 560), CGPoint(x: 230, y: 390), CGPoint(x: 300, y: 390), CGPoint(x: 250, y: 250),
            CGPoint(x: 380, y: 430), CGPoint(x: 310, y: 430), CGPoint(x: 380, y: 560),
        ])
        bolt.closeSubpath()
        fill(context, palette.accent, bolt)
    case .lens:
        for y in stride(from: CGFloat(230), to: side, by: 24) {
            fill(context, palette.shape, CGPath(rect: CGRect(x: 0, y: y, width: side, height: 10), transform: nil))
        }
        let center = CGPoint(x: 270, y: 430)
        fill(context, palette.background, circle(center, 118))
        stroke(context, palette.accent, width: 20, circle(center, 108))
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: center.x + 80, y: center.y - 80))
        handle.addLine(to: CGPoint(x: center.x + 170, y: center.y - 170))
        context.setLineCap(.round)
        stroke(context, palette.accent, width: 30, handle)
    case .planet(let moons, let rotation):
        for (index, point) in [(80, 560), (520, 520), (140, 300), (470, 270), (300, 580), (40, 400)].enumerated() {
            fill(context, palette.accent, circle(CGPoint(x: point.0, y: point.1), index.isMultiple(of: 2) ? 3 : 2))
        }
        let center = CGPoint(x: side / 2, y: 410)
        fill(context, palette.shape, circle(center, 130))
        // Flat bands across the planet, clipped to it.
        context.saveGState()
        context.addPath(circle(center, 130))
        context.clip()
        for offset in [CGFloat(-70), -10, 55] {
            let band = CGRect(x: center.x - 140, y: center.y + offset, width: 280, height: 18)
            fill(
                context, palette.accent.withAlphaComponent(1).blended(withFraction: 0.5, of: palette.shape)!,
                CGPath(rect: band, transform: nil))
        }
        context.restoreGState()
        for moon in 0..<moons {
            let angle = rotation + CGFloat(moon) * 2.1
            let moonCenter = CGPoint(x: center.x + cos(angle) * 190, y: center.y + sin(angle) * 150)
            fill(context, palette.accent, circle(moonCenter, 18 - CGFloat(moon) * 3))
        }
    }
}

func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
    return NSFont(descriptor: serif, size: size) ?? base
}

/// Draws `text` centred in `rect`, shrinking it until it fits.
func drawText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0)
{
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    var size = size
    while true {
        let string = NSAttributedString(
            string: text,
            attributes: [
                .font: serifFont(size: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph,
                .kern: kern,
            ])
        let bounds = string.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        if bounds.height <= rect.height || size <= 12 {
            let origin = CGPoint(x: rect.minX, y: rect.minY + (rect.height - bounds.height) / 2)
            string.draw(
                with: CGRect(origin: origin, size: CGSize(width: rect.width, height: bounds.height)),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            return
        }
        size -= 2
    }
}

func render(_ cover: Cover) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let palette = cover.palette
    fill(context, palette.background, CGPath(rect: CGRect(x: 0, y: 0, width: side, height: side), transform: nil))
    drawMotif(cover.motif, palette, in: context)
    // The text panel: a band of the background colour below the motif.
    fill(context, palette.background, CGPath(rect: CGRect(x: 0, y: 0, width: side, height: 220), transform: nil))
    fill(context, palette.accent, CGPath(rect: CGRect(x: 250, y: 214, width: 100, height: 6), transform: nil))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawText(
        cover.title, in: CGRect(x: 40, y: 70, width: side - 80, height: 130), size: 56, weight: .bold,
        color: palette.text)
    drawText(
        cover.author.uppercased(), in: CGRect(x: 40, y: 26, width: side - 80, height: 36), size: 22, weight: .medium,
        color: palette.text, kern: 3)
    if let series = cover.series {
        drawText(
            series.uppercased(), in: CGRect(x: 40, y: 548, width: side - 80, height: 34), size: 20, weight: .semibold,
            color: palette.text, kern: 4)
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

let directory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Audiobookshelf/Fixtures/Resources", isDirectory: true)
for cover in covers {
    let url = directory.appendingPathComponent("fixture-cover-\(cover.id).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Can't write \(url.path)") }
    CGImageDestinationAddImage(destination, render(cover), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    print("\(url.lastPathComponent)\t\(size / 1024) KB")
}
