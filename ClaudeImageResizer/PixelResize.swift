import Cocoa

// Pixel-exact bitmap handling, shared by the menu bar app and the standalone
// script. Both entry points have to agree on what "the image's size" means:
// NSImage.size reports points, which on a Retina capture is half the pixels, and
// the script used to read it — so a 3136x2000 screenshot looked like 1568x1000
// and sailed through untouched.

/// The image's real pixel dimensions, as Claude will see them.
func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
    if let bitmap = bitmapRepresentation(of: image) {
        return (bitmap.pixelsWide, bitmap.pixelsHigh)
    }
    // Only reachable for an image with no bitmap backing at all, where points are
    // the only measurement available.
    return (Int(image.size.width), Int(image.size.height))
}

func bitmapRepresentation(of image: NSImage) -> NSBitmapImageRep? {
    guard let tiffData = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiffData)
}

/// Redraws `image` at exactly `size` pixels, returning the bitmap so callers can
/// encode it without a TIFF round-trip.
///
/// Never upscales: a target at least as large as the source is a no-op that
/// returns the source bitmap. Enlarging costs bytes and adds interpolation blur
/// without adding anything Claude can read.
func redraw(_ image: NSImage, toPixelSize size: (width: Int, height: Int)) -> NSBitmapImageRep? {
    let current = pixelSize(of: image)
    guard size.width < current.width || size.height < current.height else {
        return bitmapRepresentation(of: image)
    }

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size.width,
        pixelsHigh: size.height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    // One point per pixel, so nothing downstream re-applies a Retina scale factor.
    bitmap.size = NSSize(width: size.width, height: size.height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    return bitmap
}
