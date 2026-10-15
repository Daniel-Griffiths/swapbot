import AppKit

private typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

extension AppDelegate {
    func captureMenu(to url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let snap = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    self.writeMenuImage(to: url)
                    self.statusItem.menu?.cancelTracking()
                    NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(snap, forMode: .common)
            RunLoop.main.add(snap, forMode: .eventTracking)
            self.statusItem.button?.performClick(nil)
        }
    }

    private func writeMenuImage(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            print("screenshot: CGWindowListCreateImage unavailable")
            return
        }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        for (index, window) in windows.enumerated() {
            guard let image = create(.null, 1 << 3, UInt32(truncatingIfNeeded: window.windowNumber), 1 | 8)?.takeRetainedValue() else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            let out = url.deletingPathExtension().appendingPathExtension("\(index).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("screenshot: \(window.windowNumber) \(type(of: window)) \(image.width)x\(image.height) -> \(out.path)")
        }
    }
}
