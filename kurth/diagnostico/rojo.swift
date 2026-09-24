import AppKit
// rojo <windowNumber> x y w h (coordenadas de pantalla con origen arriba) — ventana roja justo detrás
let a = CommandLine.arguments
let num = Int(a[1])!
let (x, y, w, h) = (Double(a[2])!, Double(a[3])!, Double(a[4])!, Double(a[5])!)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screenH = NSScreen.screens[0].frame.height
let win = NSWindow(contentRect: NSRect(x: x, y: screenH - y - h, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
win.backgroundColor = .systemRed
win.order(.below, relativeTo: num)
DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { app.terminate(nil) }
app.run()
