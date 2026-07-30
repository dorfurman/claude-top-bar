import AppKit

// Renders AppIcon.icns: an original pixel crab (not Anthropic's Clawd — its own
// silhouette, palette, pincers, eye highlights and blush) on the app's dark surface.
//
//   swiftc -parse-as-library tools/make_icon.swift -o /tmp/icon_gen && /tmp/icon_gen
//   iconutil -c icns AppIcon.iconset && rm -r AppIcon.iconset

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// b body, d dark shade, l light blush, k black, w white, . empty
let art = [
    "...bb......................bb...",
    "..bddb....................bddb..",
    ".bb..bb..................bb..bb.",
    ".bb..bbb................bbb..bb.",
    ".bbb..bb................bb..bbb.",
    "..bbbbbb................bbbbbb..",
    "...bbbb..................bbbb...",
    "....bbb..................bbb....",
    ".....bb..................bb.....",
    "......bb................bb......",
    ".......bbbbbbbbbbbbbbbbbb.......",
    ".....bbbbbbbbbbbbbbbbbbbbbb.....",
    "....bbbbbbbbbbbbbbbbbbbbbbbb....",
    "...bbbbbkkbbbbbbbbbbkkbbbbbb....",
    "...bbbbkwwkbbbbbbbbkwwkbbbbbb...",
    "...bbbbkkkkbbbbbbbbkkkkbbbbbb...",
    "...bbbbbkkbbbbbddbbbbkkbbbbbb...",
    "...bbbbbbbbbbbbddbbbbbbbbbbbb...",
    "....bbllllbbbbbbbbbbbbllllbb....",
    ".....bbbbbbbbbbbbbbbbbbbbbb.....",
    "....bb...bbb........bbb...bb....",
    "...bb....bb..........bb....bb...",
    "..bb....bb............bb....bb..",
    "..b.....b..............b.....b..",
]
let pal: [Character: NSColor] = [
    "b": NSColor(hex: 0xE07856), "d": NSColor(hex: 0xB85B3F),
    "l": NSColor(hex: 0xEFA084), "k": NSColor(hex: 0x141414),
    "w": NSColor(hex: 0xFFFFFF),
]

func crab(center: NSPoint, cell: CGFloat) {
    NSGraphicsContext.current?.shouldAntialias = false
    let cols = CGFloat(art[0].count), rows = CGFloat(art.count)
    let origin = NSPoint(x: (center.x - cols * cell / 2).rounded(),
                         y: (center.y - rows * cell / 2).rounded())
    for (r, line) in art.enumerated() {
        for (c, ch) in line.enumerated() where ch != "." {
            pal[ch]!.setFill()
            NSRect(x: origin.x + CGFloat(c) * cell, y: origin.y + (rows - 1 - CGFloat(r)) * cell,
                   width: cell, height: cell).fill()
        }
    }
    NSGraphicsContext.current?.shouldAntialias = true
}

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)
    // Apple icon grid: content inset ~10%, corner radius ~22.4% of the content square.
    let inset = s * 0.098
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.224, yRadius: box.width * 0.224)
    NSColor(hex: 0x1A1A19).setFill(); bg.fill()
    NSColor(hex: 0xFFFFFF, alpha: 0.08).setStroke()
    bg.lineWidth = max(1, s / 512); bg.stroke()

    // whole-point cells for crisp art; below 1pt (16/32px sizes) keep the fraction
    let raw = box.width * 0.84 / CGFloat(art[0].count)
    crab(center: NSPoint(x: box.midX, y: box.midY), cell: raw < 1 ? raw : raw.rounded())
    return rep
}

@main enum MakeIcon {
    static func main() throws {
        let iconset = "AppIcon.iconset"
        try? FileManager.default.removeItem(atPath: iconset)
        try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                            (256, 1), (256, 2), (512, 1), (512, 2)] {
            let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
            try render(px: pt * scale).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
        }
        print("wrote \(iconset) — now: iconutil -c icns \(iconset)")
    }
}
