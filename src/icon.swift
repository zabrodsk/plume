// Generates AppIcon.iconset (and you should run iconutil afterwards).
// Run: swift icon.swift

import AppKit
import Foundation

func makeIcon(size: Int, fileURL: URL) {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    // Background — dark warm rounded square (macOS auto-clips to its
    // squircle, but we draw a roundrect anyway so the fall-back rendering
    // outside the dock looks intentional).
    let bg = NSColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 1.0)
    bg.setFill()
    let radius = s * 0.225
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: radius, yRadius: radius).fill()

    // The glyph: italic serif lowercase "p" — distinctive at every size,
    // and the descender visually balances the squared frame.
    let fontSize = s * 0.62
    let italicSerif: NSFont = {
        if let f = NSFont(name: "NewYork-MediumItalic", size: fontSize) { return f }
        if let f = NSFont(name: "NewYork-Italic", size: fontSize) { return f }
        if let f = NSFont(name: "Times-Italic", size: fontSize) { return f }
        if let f = NSFont(name: "Georgia-Italic", size: fontSize) { return f }
        return NSFont.systemFont(ofSize: fontSize, weight: .light)
    }()

    let cream = NSColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 1.0)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: italicSerif,
        .foregroundColor: cream,
        .kern: 0
    ]
    let str = NSAttributedString(string: "p", attributes: attrs)
    let strSize = str.size()
    // Optical centering — descender pushes the visual mass slightly low,
    // so nudge baseline up a touch.
    let x = (s - strSize.width) / 2
    let y = (s - strSize.height) / 2 - s * 0.04
    str.draw(at: NSPoint(x: x, y: y))

    img.unlockFocus()

    let bitmap = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    try! png.write(to: fileURL)
}

let here = FileManager.default.currentDirectoryPath
let iconsetDir = "\(here)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in entries {
    let url = URL(fileURLWithPath: "\(iconsetDir)/\(name)")
    makeIcon(size: size, fileURL: url)
}
print("✓ wrote \(entries.count) PNGs to \(iconsetDir)")
