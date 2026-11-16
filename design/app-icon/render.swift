// Renders an SVG to a square PNG with WebKit.
// Usage: swift render.swift <in.svg> <out.png> <pixels>
import Cocoa
import WebKit

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let pixels = CGFloat(Double(args[3])!)
let side: CGFloat = 1024

final class Shooter: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = NSRect(x: 0, y: 0, width: side, height: side)
            cfg.snapshotWidth = NSNumber(value: Double(pixels / (NSScreen.main?.backingScaleFactor ?? 2)))
            webView.takeSnapshot(with: cfg) { image, error in
                guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    print("snapshot failed: \(String(describing: error))"); exit(1)
                }
                let rep = NSBitmapImageRep(cgImage: cg)
                try! rep.representation(using: .png, properties: [:])!.write(to: output)
                print("\(output.lastPathComponent): \(cg.width)x\(cg.height)")
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: side, height: side),
                      styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: side, height: side))
window.contentView = web
window.orderBack(nil)
let shooter = Shooter()
web.navigationDelegate = shooter
let svg = try! String(contentsOf: input, encoding: .utf8)
web.loadHTMLString("<html><body style='margin:0;overflow:hidden'>\(svg)</body></html>", baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(2) }
app.run()
