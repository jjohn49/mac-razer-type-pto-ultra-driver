// Renders the app icon: a graphite keycap grid with one key lit by the white
// backlight this keyboard has. Run: swift scripts/make-icon.swift OUTDIR
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high
    // macOS icon grid: the rounded square occupies ~82% of the canvas.
    let inset = s * 0.09
    let plate = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = plate.width * 0.225
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Soft drop shadow like system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(platePath); ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // Graphite gradient on the plate.
    ctx.saveGState(); ctx.addPath(platePath); ctx.clip()
    let plateGradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1), CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(plateGradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    // Keycap grid: 4 rows, staggered like a real board. Row 0 is the top row.
    let rows: [[CGFloat]] = [[1,1,1,1,1,1], [1.5,1,1,1,1,1.5], [1.75,1,1,1,1,1.25], [1.25,1.25,4,1.25,1.25]]
    let gap = plate.width * 0.028
    let unit = (plate.width * 0.76 - gap * 5) / 7
    let capH = unit * 0.92
    let gridH = CGFloat(rows.count) * capH + CGFloat(rows.count - 1) * gap
    var y = plate.midY + gridH / 2 - capH
    let litRow = 1, litCol = 2
    for (r, row) in rows.enumerated() {
        let rowW = row.reduce(0, +) * unit + CGFloat(row.count - 1) * gap
        var x = plate.midX - rowW / 2
        for (c, w) in row.enumerated() {
            let cap = CGRect(x: x, y: y, width: w * unit, height: capH)
            let capPath = CGPath(roundedRect: cap, cornerWidth: capH * 0.22, cornerHeight: capH * 0.22, transform: nil)
            let lit = r == litRow && c == litCol
            if lit {
                // The backlight: a wide soft glow under one warm-white key.
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: s * 0.07, color: CGColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 0.95))
                ctx.addPath(capPath); ctx.setFillColor(CGColor(srgbRed: 1, green: 0.98, blue: 0.93, alpha: 1)); ctx.fillPath()
                ctx.restoreGState()
                ctx.addPath(capPath); ctx.setFillColor(CGColor(srgbRed: 1, green: 0.98, blue: 0.93, alpha: 1)); ctx.fillPath()
            } else {
                ctx.addPath(capPath); ctx.setFillColor(CGColor(srgbRed: 0.33, green: 0.34, blue: 0.37, alpha: 1)); ctx.fillPath()
                // Subtle top highlight on each cap.
                let hi = CGRect(x: cap.minX + capH * 0.12, y: cap.maxY - capH * 0.3, width: cap.width - capH * 0.24, height: capH * 0.18)
                ctx.addPath(CGPath(roundedRect: hi, cornerWidth: capH * 0.09, cornerHeight: capH * 0.09, transform: nil))
                ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.41, blue: 0.44, alpha: 1)); ctx.fillPath()
            }
            x += w * unit + gap
        }
        y -= capH + gap
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) throws {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 1) }
}
// Asset catalog sizes (points @1x/@2x) and an iconset for icns.
let catalog: [(Int, String)] = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
var images: [[String: String]] = []
for (px, name) in catalog {
    let file = "icon_\(name).png"
    try write(render(px), file)
    let parts = name.split(separator: "@"); let scale = parts.count > 1 ? String(parts[1]) : "1x"
    images.append(["filename": file, "idiom": "mac", "scale": scale, "size": String(parts[0])])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(catalog.count) icon sizes to \(outDir.path)")
