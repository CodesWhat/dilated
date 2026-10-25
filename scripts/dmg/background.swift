import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else { exit(2) }
let output = URL(fileURLWithPath: arguments[1])
let width = 660
let height = 400
let red = NSColor(srgbRed: 0.76, green: 0.12, blue: 0.12, alpha: 1)
let yellow = NSColor(srgbRed: 0.98, green: 0.83, blue: 0.25, alpha: 1)

func text(
  _ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, mono: Bool = false
) {
  let font =
    mono
    ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    : NSFont.systemFont(ofSize: size, weight: .heavy)
  (value as NSString).draw(
    at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
}

for scale in [1, 2] {
  guard
    let context = CGContext(
      data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { exit(1) }
  context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  yellow.setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
  red.setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: 62)).fill()
  text("DILATED", x: 52, y: 320, size: 42, color: red)
  text(
    "DRAG TO APPLICATIONS. KEEP YOUR WORK AWAKE.", x: 54, y: 292, size: 12, color: red, mono: true)
  text("macOS 26+ / APPLE SILICON", x: 54, y: 23, size: 12, color: yellow, mono: true)
  red.setFill()
  let unit: CGFloat = 6
  for x in -9...2 where (x + 9) % 3 != 2 {
    NSBezierPath(rect: NSRect(x: 330 + CGFloat(x) * unit, y: 210, width: unit, height: unit)).fill()
  }
  for x in 0..<5 {
    for y in -(4 - x)...(4 - x) {
      NSBezierPath(
        rect: NSRect(
          x: 330 + CGFloat(3 + x) * unit, y: 210 + CGFloat(y) * unit, width: unit, height: unit)
      ).fill()
    }
  }
  NSGraphicsContext.restoreGraphicsState()
  guard let image = context.makeImage() else { exit(1) }
  let bitmap = NSBitmapImageRep(cgImage: image)
  bitmap.size = NSSize(width: width, height: height)
  let name = scale == 1 ? "background.png" : "background@2x.png"
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: output.appendingPathComponent(name))
}
