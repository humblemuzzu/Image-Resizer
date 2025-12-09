#!/usr/bin/env swift

// Claude Image Resizer - Simple Script Version
// Run with: swift ClaudeImageResizer.swift
// Or make executable: chmod +x ClaudeImageResizer.swift && ./ClaudeImageResizer.swift

import Cocoa

// Claude optimal dimension limit (keep both sides ≤ 1568px)
let MAX_DIMENSION: CGFloat = 1568

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
        print("✅ Claude Image Resizer started")
        print("📐 Max dimension: \(Int(MAX_DIMENSION))px")
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
        
        let width = image.size.width
        let height = image.size.height
        
        let timestamp = Self.dateFormatter.string(from: Date())
        let sizeDescription = "\(Int(width))x\(Int(height))"
        
        let needsResize = width > MAX_DIMENSION || height > MAX_DIMENSION
        
        // Skip if both dimensions are within the limit
        if !needsResize {
            print("[\(timestamp)] ✅ Within limit: \(sizeDescription) (no resize needed)")
            return
        }
        
        // Calculate scale
        let scale = width > height ? MAX_DIMENSION / width : MAX_DIMENSION / height
        let newWidth = width * scale
        let newHeight = height * scale
        
        // Resize
        let newImage = NSImage(size: NSSize(width: newWidth, height: newHeight))
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight),
                   from: NSRect(x: 0, y: 0, width: width, height: height),
                   operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        
        // Write back to clipboard
        pasteboard.clearContents()
        var writers: [NSPasteboardWriting] = [newImage]
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setData(tiffData, forType: .tiff)
            item.setData(pngData, forType: .png)
            writers.append(item)
        }
        
        pasteboard.writeObjects(writers)
        lastChangeCount = pasteboard.changeCount
        
        print("[\(timestamp)] 📐 Resized: \(sizeDescription) → \(Int(newWidth))x\(Int(newHeight))")
    }
}

// Run the monitor
let monitor = ClipboardMonitor()

// Create a timer on the main run loop
let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    monitor.checkClipboard()
}

// Keep the script running
RunLoop.main.run()
