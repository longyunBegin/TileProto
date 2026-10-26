// TileProto 应用图标：程序化绘制，圆角深底 + 一大两小三块磁贴（呼应 Grid 布局）
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                      xRadius: 230, yRadius: 230)
NSColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1).setFill()
bg.fill()

func tile(_ r: NSRect, _ c: NSColor) {
    let p = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)
    c.setFill()
    p.fill()
}

let m: CGFloat = 128  // 外边距
let g: CGFloat = 48   // 磁贴间距
let bigW = (size - m * 2 - g) * 0.56
let smallX = m + bigW + g
let smallW = size - m - smallX
let smallH = (size - m * 2 - g) / 2
tile(NSRect(x: m, y: m, width: bigW, height: size - m * 2),
     NSColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
tile(NSRect(x: smallX, y: m + smallH + g, width: smallW, height: smallH),
     NSColor(red: 0.72, green: 0.73, blue: 0.78, alpha: 1))
tile(NSRect(x: smallX, y: m, width: smallW, height: smallH),
     NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1))  // 强调色点缀
img.unlockFocus()

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: "/tmp/TileProtoIcon.png"))
print("icon png ok")
