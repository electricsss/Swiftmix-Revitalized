import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIconBase.png"
let size = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
canvas.fill()

let configuration = NSImage.SymbolConfiguration(pointSize: 620, weight: .regular)
guard let symbol = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) else {
    fatalError("The slider.vertical.3 SF Symbol is unavailable")
}

let symbolRect = NSRect(x: 172, y: 172, width: 680, height: 680)
symbol.draw(
    in: symbolRect,
    from: NSRect.zero,
    operation: NSCompositingOperation.sourceOver,
    fraction: 1
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
