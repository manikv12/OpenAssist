#!/usr/bin/env swift

import AppKit

// MARK: - Load the transparent logo PNG

let logoImagePath = FileManager.default.currentDirectoryPath + "/Assets/AppLogo.png"

func loadLogoPNG() -> NSImage? {
    guard let img = NSImage(contentsOfFile: logoImagePath) else {
        print("ERROR: Could not load logo PNG from \(logoImagePath)")
        return nil
    }
    return img
}

// MARK: - Trim transparent padding

func trimmedToContent(_ image: NSImage) -> NSImage {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return image }

    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    var minX = w, minY = h, maxX = 0, maxY = 0

    for y in 0..<h {
        for x in 0..<w {
            let color = rep.colorAt(x: x, y: y)
            if let a = color?.alphaComponent, a > 0.15 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return image }

    // No extra margin — we want edge-to-edge
    let margin = 0
    minX = max(0, minX - margin)
    minY = max(0, minY - margin)
    maxX = min(w - 1, maxX + margin)
    maxY = min(h - 1, maxY + margin)

    let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let cgImage = rep.cgImage?.cropping(to: cropRect) else { return image }

    let trimmed = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    print("Trimmed from \(w)x\(h) to \(cgImage.width)x\(cgImage.height)")
    return trimmed
}

// MARK: - Rendering

@MainActor
func renderIcon(size: Int, logo: NSImage) -> NSImage? {
    let s = CGFloat(size)
    let result = NSImage(size: NSSize(width: s, height: s))
    result.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let center = CGPoint(x: s / 2, y: s / 2)

    // Full-canvas radial gradient (fills corners too for macOS rounded rect)
    // Deep navy tones
    let bgColors = [
        CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1.0),   // deep navy center
        CGColor(red: 0.03, green: 0.08, blue: 0.16, alpha: 1.0),   // slightly bluer mid
        CGColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1.0),   // dark teal-navy edge
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 0.5, 1]) {
        ctx.drawRadialGradient(bgGrad,
            startCenter: CGPoint(x: s * 0.45, y: s * 0.55),
            startRadius: 0,
            endCenter: center,
            endRadius: s * 0.72,
            options: [.drawsAfterEndLocation])
    }

    // Scale logo down slightly so it sits well within the macOS rounded mask
    let logoScale: CGFloat = 0.88
    let logoSize = s * logoScale
    let logoRect = CGRect(
        x: (s - logoSize) / 2,
        y: (s - logoSize) / 2,
        width: logoSize,
        height: logoSize
    )

    // White circle filling entire area inside the gold ring
    let innerCircleInset = s * 0.09
    let innerCircleRect = CGRect(
        x: innerCircleInset,
        y: innerCircleInset,
        width: s - (innerCircleInset * 2),
        height: s - (innerCircleInset * 2)
    )
    ctx.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0))
    ctx.addEllipse(in: innerCircleRect)
    ctx.fillPath()

    // Draw the full logo on top at full opacity
    logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    result.unlockFocus()
    return result
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        print("Failed to write \(path): \(error)")
    }
}

// MARK: - Main

@MainActor
func main() {
let projectDir = FileManager.default.currentDirectoryPath
let iconsetDir = "/tmp/OpenAssistIcon.iconset"
let resourcesDir = projectDir + "/Resources"

guard let rawLogo = loadLogoPNG() else {
    print("Cannot proceed without logo image.")
    return
}
let logo = trimmedToContent(rawLogo)
print("Logo ready: \(logo.size)")

// Create iconset directory
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Generate all required sizes
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for entry in sizes {
    print("Rendering \(entry.name) (\(entry.pixels)px)...")
    if let img = renderIcon(size: entry.pixels, logo: logo) {
        savePNG(img, to: "\(iconsetDir)/\(entry.name).png")
    }
}

// Also save 1024px as AppIcon.png
if let fullImg = renderIcon(size: 1024, logo: logo) {
    savePNG(fullImg, to: "\(resourcesDir)/AppIcon.png")
    print("Saved AppIcon.png")
}

// Run iconutil to create .icns
print("Creating .icns...")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir, "-o", "\(resourcesDir)/AppIcon.icns"]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Done! AppIcon.icns created successfully.")
} else {
    print("iconutil failed with status \(process.terminationStatus)")
}
} // end main()

MainActor.assumeIsolated { main() }
exit(0)
