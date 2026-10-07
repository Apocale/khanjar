import AppKit

/// Images de la documentation (README) dessinées par l'app elle-même : ce sont les
/// vraies vues de Khanjar, rendues hors écran (aucune capture d'écran, aucune
/// permission « Enregistrement de l'écran » nécessaire). Mode CLI : render-media.
enum Snapshot {
    /// Dessine `view` en PNG à l'échelle voulue, dans l'apparence donnée. Le fond
    /// « verre » (NSVisualEffectView) ne se compose pas hors écran : `backdrop`
    /// peint la teinte qu'il aurait, sous les vues.
    static func png(of view: NSView, scale: CGFloat = 2, dark: Bool, backdrop: NSColor? = nil) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            view.appearance = appearance
            view.layoutSubtreeIfNeeded()
            let size = view.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            if let backdrop {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let radius = view.layer?.cornerRadius ?? 0
                backdrop.setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }
}
