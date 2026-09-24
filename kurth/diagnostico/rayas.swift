import AppKit
// rayas <windowNumber> x y w h [segundos] — rayas negras y blancas de 12 pt justo detrás de esa ventana
let a = CommandLine.arguments
let num = Int(a[1])!
let (x, y, w, h) = (Double(a[2])!, Double(a[3])!, Double(a[4])!, Double(a[5])!)
let secs = a.count > 6 ? Double(a[6])! : 2.2
final class Stripes: NSView {
    override func draw(_ r: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor.black.setFill()
        var x = 0.0
        while x < bounds.width { NSRect(x: x, y: 0, width: 12, height: bounds.height).fill(); x += 24 }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screenH = NSScreen.screens[0].frame.height
let win = NSWindow(contentRect: NSRect(x: x, y: screenH - y - h, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = Stripes()
win.order(.below, relativeTo: num)
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { app.terminate(nil) }
app.run()
