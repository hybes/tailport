import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("tailport-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: iconset) }
let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
             ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
             ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, size) in sizes {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    context.setFillColor(CGColor(red: 0.12, green: 0.34, blue: 0.68, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.fillPath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(48)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 300, y: 630))
    context.addLine(to: CGPoint(x: 724, y: 630))
    context.addLines(between: [CGPoint(x: 625, y: 729), CGPoint(x: 724, y: 630), CGPoint(x: 625, y: 531)])
    context.move(to: CGPoint(x: 724, y: 394))
    context.addLine(to: CGPoint(x: 300, y: 394))
    context.addLines(between: [CGPoint(x: 399, y: 295), CGPoint(x: 300, y: 394), CGPoint(x: 399, y: 493)])
    context.strokePath()
    let url = iconset.appendingPathComponent(name + ".png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "iconutil failed")
