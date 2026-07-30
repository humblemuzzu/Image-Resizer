// Claude Image Resizer - Simple Script Version
//
// No longer runnable with `swift ClaudeImageResizer.swift`: the budget maths now
// lives in ClaudeImageResizer/ImageBudget.swift so that this file and the menu bar
// app can never disagree about Claude's limits again. They used to, and this file
// was the one that was wrong. `./build.sh` compiles it to
// build/claude-image-resizer-script, or:
//
//   swiftc -O ClaudeImageResizer/ImageBudget.swift ClaudeImageResizer/ImageBudgetSelfTest.swift \
//       ClaudeImageResizer/PixelResize.swift ClaudeImageResizer.swift \
//       -o build/claude-image-resizer-script -framework Cocoa

import Cocoa

/// Spec §2. The script has no UI to change this; the menu bar app does.
let tier = ResolutionTier.standard

class ClipboardMonitor {
    let pasteboard = NSPasteboard.general
    var lastChangeCount: Int
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        lastChangeCount = pasteboard.changeCount
        let limits = tier.limits
        print("✅ Claude Image Resizer started")
        print("📐 \(tier.displayName): \(limits.maxTokens) visual tokens, \(limits.maxEdge)px max edge")
        print("👀 Monitoring clipboard... (Press Ctrl+C to stop)")
        print("")
    }

    func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Try to get image from clipboard
        guard let image = NSImage(pasteboard: pasteboard) ??
              (pasteboard.data(forType: .tiff).flatMap { NSImage(data: $0) }) ??
              (pasteboard.data(forType: .png).flatMap { NSImage(data: $0) }) else {
            return
        }

        // PIXEL dimensions, not points. This file used to read NSImage.size, which
        // on Retina is half the pixels, so a 3136x2000 capture measured 1568x1000
        // and was passed through untouched - the exact failure the app exists to
        // prevent.
        let source = pixelSize(of: image)

        let timestamp = Self.dateFormatter.string(from: Date())
        let sourceDescription = "\(source.width)x\(source.height)"
        let sourceTokens = ImageBudget.countImageTokens(width: source.width, height: source.height)

        // Spec §4: the token budget binds long before the edge limit does.
        guard let target = ImageBudget.targetSize(width: source.width, height: source.height, limits: tier.limits) else {
            print("[\(timestamp)] ✅ Within limits: \(sourceDescription) (\(sourceTokens) tokens, no resize needed)")
            return
        }

        guard let bitmap = redraw(image, toPixelSize: target),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("[\(timestamp)] ⚠️ Could not re-encode \(sourceDescription); clipboard left untouched")
            return
        }

        // Only the PNG goes on the pasteboard. A TIFF representation is
        // uncompressed and would undo the point of the exercise.
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount

        let newTokens = ImageBudget.countImageTokens(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        print("[\(timestamp)] 📐 Resized: \(sourceDescription) → \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) (\(sourceTokens) → \(newTokens) tokens)")

        // Spec §7: the limit is on the base64 payload, not the raw bytes. The script
        // has no compression ladder, so it says so rather than shipping it quietly.
        let payload = ImageBudget.base64Bytes(pngData.count)
        if payload > ImageBudget.maxBase64Bytes {
            print("[\(timestamp)] ⚠️ Payload is \(payload) bytes base64, over the \(ImageBudget.maxBase64Bytes) limit. Use the menu bar app, which compresses.")
        }
    }
}

@main
struct ClaudeImageResizerScript {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(ImageBudgetSelfTest.run() ? 0 : 1)
        }

        let monitor = ClipboardMonitor()
        _ = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            monitor.checkClipboard()
        }
        RunLoop.main.run()
    }
}
