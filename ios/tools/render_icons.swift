import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: root.appendingPathComponent("Contents.json"))
let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
var done = Set<String>()
for entry in manifest["images"] as! [[String: Any]] {
    let name = entry["filename"] as! String
    if done.contains(name) { continue }; done.insert(name)
    let base = Double((entry["size"] as! String).split(separator: "x")[0])!
    let scale = Double((entry["scale"] as! String).dropLast())!
    let size = Int(base * scale)
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 8.0/255, green: 127.0/255, blue: 121.0/255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: s, height: s))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(s * 0.035); context.setLineCap(.round)
    for radius in [CGFloat(0.32), CGFloat(0.22), CGFloat(0.12)] {
        context.addArc(center: CGPoint(x: s/2, y: s*0.34), radius: s*radius,
            startAngle: 0, endAngle: .pi, clockwise: false)
        context.strokePath()
    }
    let r = s*0.045
    context.fillEllipse(in: CGRect(x: s/2-r, y: s*0.34-r, width: 2*r, height: 2*r))
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
}
print("Rendered \(done.count) opaque NSControl icons")
