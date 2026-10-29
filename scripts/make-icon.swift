import AppKit
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 208, yRadius: 208)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.38, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.14, alpha: 1))!.draw(in: tile, angle: -65)
NSColor(calibratedRed: 0.58, green: 0.72, blue: 1, alpha: 0.16).setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 186, y: 186, width: 652, height: 652)); ring.lineWidth = 5; ring.stroke()
let body = NSBezierPath(roundedRect: NSRect(x: 290, y: 266, width: 444, height: 492), xRadius: 190, yRadius: 190)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 35; shadow.shadowOffset = NSSize(width: 0, height: -18)
NSGraphicsContext.saveGraphicsState(); shadow.set()
NSGradient(starting: NSColor(calibratedRed: 0.77, green: 0.87, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.91, alpha: 1))!.draw(in: body, angle: -65)
NSGraphicsContext.restoreGraphicsState()
NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.31, alpha: 1).setFill()
for x in [427.0, 571.0] { NSBezierPath(roundedRect: NSRect(x: x, y: 508, width: 26, height: 46), xRadius: 13, yRadius: 13).fill() }
let smile = NSBezierPath(); smile.move(to: NSPoint(x: 473, y: 442)); smile.curve(to: NSPoint(x: 551, y: 442), controlPoint1: NSPoint(x: 492, y: 411), controlPoint2: NSPoint(x: 532, y: 411)); smile.lineWidth = 12; smile.lineCapStyle = .round; NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.31, alpha: 1).setStroke(); smile.stroke()
NSColor.white.withAlphaComponent(0.45).setFill(); NSBezierPath(roundedRect: NSRect(x: 369, y: 665, width: 91, height: 19), xRadius: 10, yRadius: 10).fill()
for i in 0..<3 { NSColor(calibratedRed: 0.45, green: 0.88, blue: 0.77, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 758, y: 435 - i * 49, width: 90 - i * 18, height: 17), xRadius: 8, yRadius: 8).fill() }
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
