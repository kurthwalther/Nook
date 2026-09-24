import AppKit
let rep = NSBitmapImageRep(data: NSImage(contentsOfFile: CommandLine.arguments[1])!.tiffRepresentation!)!
let y = Int(CommandLine.arguments[2])!, x0 = Int(CommandLine.arguments[3])!, x1 = Int(CommandLine.arguments[4])!
var out = ""
for x in stride(from: x0, to: x1, by: 6) { let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; out += String(format: "%02X ", Int(c.greenComponent*255)) }
print(out)
