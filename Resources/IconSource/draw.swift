import AppKit
import CoreText

// Run from the repo root: swiftc -O Resources/IconSource/draw.swift -o /tmp/draw && /tmp/draw <out-dir>
let fonts = FileManager.default.currentDirectoryPath + "/Resources/Fonts/"
for f in ["EBGaramond-Regular.otf", "EBGaramond-Italic.otf", "EBGaramond-MediumItalic.otf", "EBGaramond-Medium.otf"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: fonts + f) as CFURL, .process, nil)
}
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let ground = c(0x0E0D0B), surface = c(0x1A1915), cream = c(0xEDE7DB), ink3 = c(0x7D776C), rule = c(0x2E2C27), accent = c(0xEE5A3B)

func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).cgPath
}

func render(_ name: String, size: Int = 1024, _ draw: (CGContext, CGRect) -> Void) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    // macOS grid: 824pt body inset 100, drop shadow below.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0, 0.45))
    ctx.addPath(squircle(body, 185)); ctx.setFillColor(ground); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle(body, 185)); ctx.clip()
    // Faint top light so it isn't a flat slab.
    let g = CGGradient(colorsSpace: cs, colors: [c(0x24221D), c(0x0E0D0B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 300), options: [])
    draw(ctx, body)
    ctx.restoreGState()
    ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5), 184)); ctx.setStrokeColor(c(0xFFFFFF, 0.07)); ctx.setLineWidth(3); ctx.strokePath()
    let url = URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

func text(_ ctx: CGContext, _ string: String, font: String, size: CGFloat, color: CGColor, at p: CGPoint) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attr = NSAttributedString(string: string, attributes: [.font: f, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: p.x - CGFloat(w) / 2, y: p.y)
    CTLineDraw(line, ctx)
}

func ribbon(_ ctx: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, length: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: top)); p.addLine(to: CGPoint(x: x + width, y: top))
    p.addLine(to: CGPoint(x: x + width, y: top - length)); p.addLine(to: CGPoint(x: x + width / 2, y: top - length + width * 0.55))
    p.addLine(to: CGPoint(x: x, y: top - length)); p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(accent); ctx.fillPath()
}

// A — The desk: a cream page on the left, a narrow notes pane on the right, a vermilion bookmark.
render("A-desk") { ctx, _ in
    let page = CGRect(x: 230, y: 250, width: 330, height: 524)
    ctx.addPath(squircle(page, 26)); ctx.setFillColor(cream); ctx.fillPath()
    ctx.setFillColor(c(0x1A1915, 0.28))
    for (i, w) in [180, 196, 228, 250, 190].enumerated() {
        ctx.fill(CGRect(x: 270, y: 640 - CGFloat(i) * 52, width: CGFloat(w), height: 14))
    }
    let pane = CGRect(x: 600, y: 250, width: 194, height: 524)
    ctx.addPath(squircle(pane, 26)); ctx.setStrokeColor(c(0xEDE7DB, 0.55)); ctx.setLineWidth(12); ctx.strokePath()
    ctx.setFillColor(c(0xEDE7DB, 0.3))
    for i in 0..<3 { ctx.fill(CGRect(x: 638, y: 660 - CGFloat(i) * 52, width: CGFloat([118, 96, 108][i]), height: 12)) }
    ribbon(ctx, x: 476, top: 774, width: 52, length: 190)
}

// B — The letterform: an italic Garamond R on the dark page, with a bookmark falling through it.
render("B-letter") { ctx, _ in
    ribbon(ctx, x: 610, top: 924, width: 66, length: 330)
    text(ctx, "R", font: "EBGaramond-MediumItalic", size: 640, color: cream, at: CGPoint(x: 500, y: 290))
}

// C — The shelf: book spines of different heights, one vermilion, standing on a rule.
render("C-shelf") { ctx, _ in
    let spines: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
        (250, 92, 430, cream), (356, 70, 380, c(0xB4AD9F)), (440, 104, 470, accent), (558, 78, 400, cream), (650, 120, 340, c(0x7D776C)),
    ]
    for (x, w, h, col) in spines {
        let r = CGRect(x: x, y: 300, width: w, height: h)
        ctx.addPath(squircle(r, 14)); ctx.setFillColor(col); ctx.fillPath()
        ctx.setFillColor(c(0, 0.18)); ctx.fill(CGRect(x: x + 14, y: 300 + h - 70, width: w - 28, height: 10))
    }
    // the last one leans
    ctx.setFillColor(cream); ctx.fill(CGRect(x: 225, y: 286, width: 574, height: 14))
}
