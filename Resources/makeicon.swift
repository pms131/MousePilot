// Draws the app icon (1024x1024 PNG) to the path given as argv[1].
// Every shape is a plain Bezier path: no SF Symbols, fonts or image files.
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Background: macOS-style rounded square, a gradient from sky blue to periwinkle.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.56, green: 0.86, blue: 1.00, alpha: 1),
           ending: NSColor(red: 0.33, green: 0.52, blue: 0.98, alpha: 1))!.draw(in: bg, angle: -90)

// Tab strip: three tabs, middle one active.
for (i, x) in [180.0, 405.0, 630.0].enumerated() {
    let tab = NSBezierPath(roundedRect: NSRect(x: x, y: 640, width: 214, height: 120), xRadius: 30, yRadius: 30)
    NSColor.white.withAlphaComponent(i == 1 ? 1 : 0.45).setFill()
    tab.fill()
}

// Paper plane frame: origin at the rear fold, x axis along the flight direction.
let heading = 28.0 * Double.pi / 180
let dir = (x: cos(heading), y: sin(heading))
let origin = NSPoint(x: 512, y: 332)
func plane(_ x: Double, _ y: Double) -> NSPoint {
    NSPoint(x: origin.x + x * dir.x - y * dir.y, y: origin.y + x * dir.y + y * dir.x)
}
func polygon(_ pts: [NSPoint]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pts[0])
    for q in pts.dropFirst() { p.line(to: q) }
    p.close()
    return p
}

// Gesture trail: a "down, then right" stroke of dots that leads into the plane's tail
// and fades with age (smaller and fainter the further back).
let p0 = NSPoint(x: 236, y: 522), c1 = NSPoint(x: 214, y: 316)
let p3 = plane(-95, 0)
let c2 = NSPoint(x: p3.x - 170 * dir.x, y: p3.y - 170 * dir.y)
func bezier(_ t: Double) -> NSPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return NSPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
                   y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
}
var samples: [(NSPoint, Double)] = []
var length = 0.0
var prev = bezier(0)
for k in 0...2000 {
    let pt = bezier(Double(k) / 2000)
    length += hypot(pt.x - prev.x, pt.y - prev.y)
    samples.append((pt, length))
    prev = pt
}
let dotCount = 5
var next = 0
for (pt, s) in samples where next < dotCount && s >= length * Double(next) / Double(dotCount - 1) {
    let f = Double(next) / Double(dotCount - 1)          // 0 = oldest point, 1 = right behind the plane
    let r = 22 + 12 * f
    NSColor.white.withAlphaComponent(0.48 + 0.36 * f).setFill()
    NSBezierPath(ovalIn: NSRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)).fill()
    next += 1
}

// Paper plane: the near wing in solid white, the far wing (below the fold) a shade dimmer.
let nose = plane(372, 0)
let nearTip = plane(-70, 175)
let farTip = plane(-35, -120)
let fold = plane(0, 0)
NSColor.white.setFill()
polygon([nose, nearTip, fold]).fill()
NSColor.white.withAlphaComponent(0.72).setFill()
polygon([nose, fold, farTip]).fill()

img.unlockFocus()

// Write exactly 1024x1024 pixels, whatever the screen scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = img.size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
