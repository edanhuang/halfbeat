import AppKit

// 将选定的 B 音符/歌词造型制作成可重复构建的图标；App 用白底蓝青色，菜单栏复用轮廓生成单色矢量模板。
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func logoMark() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 725, y: 805))
    path.curve(to: NSPoint(x: 763, y: 767), controlPoint1: NSPoint(x: 746, y: 805), controlPoint2: NSPoint(x: 763, y: 788))
    path.line(to: NSPoint(x: 763, y: 330))
    path.curve(to: NSPoint(x: 625, y: 188), controlPoint1: NSPoint(x: 763, y: 245), controlPoint2: NSPoint(x: 700, y: 188))
    path.curve(to: NSPoint(x: 501, y: 292), controlPoint1: NSPoint(x: 548, y: 188), controlPoint2: NSPoint(x: 494, y: 231))
    path.curve(to: NSPoint(x: 578, y: 401), controlPoint1: NSPoint(x: 501, y: 347), controlPoint2: NSPoint(x: 528, y: 382))
    path.curve(to: NSPoint(x: 674, y: 426), controlPoint1: NSPoint(x: 613, y: 423), controlPoint2: NSPoint(x: 651, y: 427))
    path.curve(to: NSPoint(x: 687, y: 439), controlPoint1: NSPoint(x: 681, y: 426), controlPoint2: NSPoint(x: 687, y: 432))
    path.line(to: NSPoint(x: 687, y: 584))
    path.line(to: NSPoint(x: 594, y: 584))
    path.curve(to: NSPoint(x: 566, y: 556), controlPoint1: NSPoint(x: 579, y: 584), controlPoint2: NSPoint(x: 566, y: 573))
    path.curve(to: NSPoint(x: 560, y: 550), controlPoint1: NSPoint(x: 566, y: 552), controlPoint2: NSPoint(x: 564, y: 550))
    path.line(to: NSPoint(x: 316, y: 550))
    path.curve(to: NSPoint(x: 265, y: 601), controlPoint1: NSPoint(x: 288, y: 550), controlPoint2: NSPoint(x: 265, y: 573))
    path.curve(to: NSPoint(x: 316, y: 652), controlPoint1: NSPoint(x: 265, y: 629), controlPoint2: NSPoint(x: 288, y: 652))
    path.line(to: NSPoint(x: 674, y: 652))
    path.curve(to: NSPoint(x: 687, y: 665), controlPoint1: NSPoint(x: 681, y: 652), controlPoint2: NSPoint(x: 687, y: 658))
    path.line(to: NSPoint(x: 687, y: 767))
    path.curve(to: NSPoint(x: 725, y: 805), controlPoint1: NSPoint(x: 687, y: 788), controlPoint2: NSPoint(x: 704, y: 805))
    path.close()
    path.append(NSBezierPath(roundedRect: NSRect(x: 162, y: 403, width: 379, height: 100), xRadius: 50, yRadius: 50))
    return path
}

func writeAppPNG(pixels: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(calibratedWhite: 0.93, alpha: 1), ending: .white)!.draw(in: tile, angle: 90)
    NSColor(calibratedWhite: 0.85, alpha: 0.5).setStroke()
    tile.lineWidth = 1
    tile.stroke()
    NSGradient(colors: [NSColor(calibratedRed: 0, green: 0.35, blue: 1, alpha: 1),
                        NSColor(calibratedRed: 0, green: 0.67, blue: 1, alpha: 1),
                        NSColor(calibratedRed: 0, green: 0.81, blue: 0.92, alpha: 1)])!
        .draw(in: logoMark(), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try writeAppPNG(pixels: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writeAppPNG(pixels: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try writeAppPNG(pixels: 1024, to: destination.appendingPathComponent("AppIcon.png"))

let mark = logoMark()
let bounds = mark.bounds
let padding: CGFloat = 20
var page = CGRect(x: 0, y: 0, width: bounds.width + padding * 2, height: bounds.height + padding * 2)
let consumer = CGDataConsumer(url: destination.appendingPathComponent("MenuBarIcon.pdf") as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &page, nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
let transform = AffineTransform(translationByX: padding - bounds.minX, byY: padding - bounds.minY)
mark.transform(using: transform)
NSColor.black.setFill()
mark.fill()
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()
