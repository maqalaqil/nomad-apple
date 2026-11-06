#!/usr/bin/env swift
// Original NOMAD Apple compass/mountain artwork. No fonts, symbols, or external art.
// Regenerate from any working directory: swift apple/scripts/generate-app-icon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let script = URL(fileURLWithPath: #filePath).standardizedFileURL
let catalog = script.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Assets.xcassets", isDirectory: true)
let icons = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: icons, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}
let forest = color(0.055, 0.085, 0.075)
let panel = color(0.095, 0.135, 0.115)
let lime = color(0.78, 0.92, 0.48)
let sage = color(0.55, 0.66, 0.59)

func polygon(_ points: [CGPoint], in context: CGContext, fill: CGColor) {
    context.beginPath()
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.closePath()
    context.setFillColor(fill)
    context.fillPath()
}

func render(pixels: Int, mac: Bool, filename: String) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // iOS has no alpha channel at all. Mac leaves a transparent margin around its tile.
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space,
        bitmapInfo: alpha.rawValue) else { fatalError("Cannot create icon context.") }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)
    if mac {
        context.translateBy(x: 64, y: 64)
        context.scaleBy(x: 0.875, y: 0.875)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
            cornerWidth: 222, cornerHeight: 222, transform: nil))
        context.clip()
    }
    context.setFillColor(forest)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let gradient = CGGradient(colorsSpace: space, colors: [forest, panel] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 80, y: 0),
        end: CGPoint(x: 940, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The ring and four ticks form a compass; mountains remain legible at small sizes.
    context.setStrokeColor(color(0.55, 0.66, 0.59, 0.68))
    context.setLineWidth(17)
    context.strokeEllipse(in: CGRect(x: 174, y: 174, width: 676, height: 676))
    context.setLineCap(.round)
    context.setStrokeColor(sage)
    context.setLineWidth(19)
    for (a, b) in [(CGPoint(x: 174, y: 512), CGPoint(x: 213, y: 512)),
                   (CGPoint(x: 811, y: 512), CGPoint(x: 850, y: 512)),
                   (CGPoint(x: 512, y: 174), CGPoint(x: 512, y: 213))] {
        context.move(to: a); context.addLine(to: b); context.strokePath()
    }
    // North-pointing needle, separated from the range by a clear band of sky.
    polygon([CGPoint(x: 512, y: 823), CGPoint(x: 564, y: 701),
             CGPoint(x: 512, y: 727), CGPoint(x: 460, y: 701)], in: context, fill: lime)
    polygon([CGPoint(x: 248, y: 338), CGPoint(x: 424, y: 620),
             CGPoint(x: 516, y: 483), CGPoint(x: 634, y: 662),
             CGPoint(x: 790, y: 338)], in: context, fill: lime)
    // Shadow facets distinguish the two peaks without fine linework.
    polygon([CGPoint(x: 424, y: 620), CGPoint(x: 424, y: 338),
             CGPoint(x: 516, y: 483)], in: context, fill: color(0.48, 0.65, 0.31))
    polygon([CGPoint(x: 634, y: 662), CGPoint(x: 634, y: 338),
             CGPoint(x: 790, y: 338)], in: context, fill: color(0.59, 0.76, 0.37))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(icons.appendingPathComponent(filename) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot encode icon.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon.") }
}

var images: [[String: String]] = []
try render(pixels: 1024, mac: false, filename: "AppIcon-iOS-1024.png")
images.append(["filename": "AppIcon-iOS-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "AppIcon-mac-\(size)x\(scale).png"
        try render(pixels: size * scale, mac: true, filename: filename)
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
for (url, object) in [(catalog.appendingPathComponent("Contents.json"), ["info": info]),
                      (icons.appendingPathComponent("Contents.json"), ["images": images, "info": info])] {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}
print("Generated 11 original app icons in \(icons.path)")
