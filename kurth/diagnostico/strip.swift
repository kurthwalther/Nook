import AppKit
let rep = NSBitmapImageRep(data: NSImage(contentsOfFile: CommandLine.arguments[1])!.tiffRepresentation!)!
let x = Int(CommandLine.arguments[2])!
var out = ""
for y in stride(from: 0, to: rep.pixelsHigh, by: rep.pixelsHigh/16) {
  let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
  out += String(format: "%02X%02X%02X ", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))
}
print(out)
