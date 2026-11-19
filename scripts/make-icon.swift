// Builds AppIcon.icns from Assets/logo.png.
// Usage: swift scripts/make-icon.swift Assets/logo.png <out.icns>
//
// The logo is an opaque square: a dark rounded tile on a black background. This finds the tile,
// measures its corner radius, and redraws it on a transparent canvas using Apple's icon grid
// (824 pt tile inside 1024 pt, with a soft shadow), at every size an .icns needs.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: make-icon.swift <logo.png> <out.icns>") }
let (input, output) = (args[1], args[2])

guard let data = FileManager.default.contents(atPath: input),
      let rep = NSBitmapImageRep(data: data), let source = rep.cgImage
else { fatalError("can't read \(input)") }

// The tile is ~#0A0A0A; the background outside it is pure black.
func isTile(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
    return max(c.redComponent, c.greenComponent, c.blueComponent) * 255 >= 6
}
let (w, h) = (rep.pixelsWide, rep.pixelsHigh)
let (midX, midY) = (w / 2, h / 2)
guard let left = (0..<w).first(where: { isTile($0, midY) }),
      let right = (0..<w).reversed().first(where: { isTile($0, midY) }),
      let top = (0..<h).first(where: { isTile(midX, $0) }),
      let bottom = (0..<h).reversed().first(where: { isTile(midX, $0) })
else { fatalError("couldn't find the logo tile") }
let tile = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)

// For a circular corner of radius r, the diagonal meets the edge at r * (1 - 1/√2) from the corner.
let diagonal = (0..<Int(tile.width / 2)).first { isTile(left + $0, top + $0) } ?? 0
let radiusFraction = (Double(diagonal) / (1 - 1 / 2.0.squareRoot())) / tile.width
guard let cropped = source.cropping(to: tile) else { fatalError("crop failed") }
print("tile \(tile), corner radius \(Int(radiusFraction * 100))% of width")

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * radiusFraction,
                      cornerHeight: body.width * radiusFraction, transform: nil)
    // Shadow (skipped at tiny sizes where it only muddies the edge).
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 22 / 1024,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(cropped, in: body)
    let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return out.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output)")
