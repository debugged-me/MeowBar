import AppKit

// The MeowBar cat as a vector silhouette (round head + two pointed ears),
// drawn once per size and cached. Rendered as a template — callers tint it
// via .foregroundStyle in SwiftUI or labelColor in AppKit, so it adapts to
// any surface. Same mark in the popover, onboarding and (via tinting) the
// menu bar.
enum CatGlyph {
    private static var cache: [Int: NSImage] = [:]
    private static var tintCache: [String: NSImage] = [:]

    static func image(size: CGFloat) -> NSImage {
        let key = Int(size * 2)
        if let img = cache[key] { return img }
        // Slightly wider than tall: a cat head reads better with cheek room.
        let s = NSSize(width: size, height: size * 0.92)
        let img = NSImage(size: s, flipped: false) { rect in
            let w = rect.width, h = rect.height
            let p = NSBezierPath()
            p.appendOval(in: NSRect(x: w * 0.10, y: h * 0.03,
                                    width: w * 0.80, height: h * 0.72))
            for tipX in [0.24, 0.76] {
                let sign: CGFloat = tipX < 0.5 ? 1 : -1
                let e = NSBezierPath()
                e.move(to: NSPoint(x: w * (0.5 - sign * 0.34), y: h * 0.56))
                e.line(to: NSPoint(x: w * tipX, y: h * 0.98))
                e.line(to: NSPoint(x: w * 0.5, y: h * 0.60))
                e.close()
                p.append(e)
            }
            // December: a floppy hat over the right ear, bobble and all.
            // Drawn into the same silhouette, so it tints with the cat.
            if Calendar.current.component(.month, from: Date()) == 12 {
                let hat = NSBezierPath()
                hat.move(to: NSPoint(x: w * 0.56, y: h * 0.60))
                hat.curve(to: NSPoint(x: w * 0.97, y: h * 0.86),
                          controlPoint1: NSPoint(x: w * 0.66, y: h * 0.97),
                          controlPoint2: NSPoint(x: w * 0.86, y: h * 0.95))
                hat.line(to: NSPoint(x: w * 0.84, y: h * 0.50))
                hat.close()
                p.append(hat)
                p.appendOval(in: NSRect(x: w * 0.93, y: h * 0.80,
                                        width: w * 0.11, height: w * 0.11))
            }
            NSColor.black.setFill()
            p.fill()
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }

    // The silhouette drawn in a specific color — for attributed-string
    // attachments, which can't take a template image's ambient tint.
    static func tinted(size: CGFloat, _ color: NSColor) -> NSImage {
        tintedImage(image(size: size), color, key: "\(size)-\(color.description)")
    }

    static func tintedImage(_ base: NSImage, _ color: NSColor, key: String) -> NSImage {
        if let img = tintCache[key] { return img }
        let img = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        tintCache[key] = img
        return img
    }

}
