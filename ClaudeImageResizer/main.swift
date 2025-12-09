import Cocoa
import UserNotifications

// MARK: - Image Resizer Core
class ClipboardImageResizer {
    static let shared = ClipboardImageResizer()
    
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    // Claude's recommended optimal dimension limit
    let maxDimension: CGFloat = 1568
    // Target file size (5MB) for Claude uploads
    let maxFileSize: Int = 5_000_000
    
    private init() {
        lastChangeCount = pasteboard.changeCount
    }
    
    func startMonitoring() {
        // Poll every 0.05 seconds (50ms) - fast enough to beat clipboard managers
        // This is still lightweight since we only check changeCount integer comparison
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        print("✅ Claude Image Resizer started - monitoring clipboard for images > \(Int(maxDimension))px")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Check if clipboard has an image
        guard let image = getImageFromPasteboard() else { return }

        // IMPORTANT: Get actual PIXEL dimensions, not point dimensions!
        // On Retina displays, image.size returns points (half of actual pixels)
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData) {
            pixelWidth = CGFloat(bitmap.pixelsWide)
            pixelHeight = CGFloat(bitmap.pixelsHigh)
        } else {
            // Fallback to point dimensions if we can't get pixel dimensions
            pixelWidth = image.size.width
            pixelHeight = image.size.height
        }
        
        let timestamp = dateFormatter.string(from: Date())
        let originalDimensions = "\(Int(pixelWidth))x\(Int(pixelHeight))"

        // Get actual clipboard data size (check JPEG first, then PNG, then estimate from TIFF)
        let originalFileSize: Int
        if let jpegData = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            originalFileSize = jpegData.count
        } else if let pngData = pasteboard.data(forType: .png) {
            originalFileSize = pngData.count
        } else {
            // Fallback to TIFF estimate (will be larger than actual compressed size)
            originalFileSize = image.tiffRepresentation?.count ?? 0
        }

        // Check if processing is needed - ONLY if PIXEL dimensions exceed limit
        let needsResize = pixelWidth > maxDimension || pixelHeight > maxDimension

        if !needsResize && originalFileSize <= maxFileSize {
            let message = "[\(timestamp)] ✅ Within limits: \(originalDimensions) (\(formatBytes(originalFileSize)))"
            print(message)
            postHistoryEvent(message: message, fileURL: nil)
            return
        }

        // Resize and compress the image using PIXEL dimensions
        if let result = resizeAndCompressPixels(image, pixelWidth: pixelWidth, pixelHeight: pixelHeight, maxDimension: maxDimension, maxSize: maxFileSize) {
            writeImageToPasteboard(result.image, imageData: result.data, format: result.format)

            // Get the actual pixel dimensions of the result
            let newPixelWidth: Int
            let newPixelHeight: Int
            if let tiffData = result.image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData) {
                newPixelWidth = bitmap.pixelsWide
                newPixelHeight = bitmap.pixelsHigh
            } else {
                newPixelWidth = Int(result.image.size.width)
                newPixelHeight = Int(result.image.size.height)
            }
            
            let newDimensions = "\(newPixelWidth)x\(newPixelHeight)"
            let savedURL = saveImageToDisk(imageData: result.data, format: result.format, timestamp: timestamp)

            let message = "[\(timestamp)] 📐 Optimized: \(originalDimensions) → \(newDimensions) (\(formatBytes(originalFileSize)) → \(formatBytes(result.data.count)))"
            print(message)
            postHistoryEvent(message: message, fileURL: savedURL)

            // Show notification with file size info
            showNotification(
                originalSize: originalDimensions,
                newSize: newDimensions,
                originalBytes: originalFileSize,
                newBytes: result.data.count,
                fileURL: savedURL
            )
        }
    }

    /// Formats bytes into human-readable string (KB, MB)
    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1fMB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.0fKB", Double(bytes) / 1_000)
        }
        return "\(bytes)B"
    }
    
    private func getImageFromPasteboard() -> NSImage? {
        // Try to get image directly
        if let image = NSImage(pasteboard: pasteboard) {
            return image
        }
        
        // Try TIFF data
        if let data = pasteboard.data(forType: .tiff),
           let image = NSImage(data: data) {
            return image
        }
        
        // Try PNG data
        if let data = pasteboard.data(forType: .png),
           let image = NSImage(data: data) {
            return image
        }
        
        return nil
    }
    
    /// Resizes image to fit within maxDimension PIXELS (not points)
    /// This creates a new bitmap at the exact pixel dimensions we want
    private func resizeImagePixels(_ image: NSImage, currentPixelWidth: CGFloat, currentPixelHeight: CGFloat, maxDimension: CGFloat) -> NSImage? {
        let longerSide = max(currentPixelWidth, currentPixelHeight)

        // Only resize if image is LARGER than maxDimension - never upscale!
        if longerSide <= maxDimension {
            return image  // Return original, no resize needed
        }

        // Calculate scale factor to fit within maxDimension PIXELS
        let scaleFactor = maxDimension / longerSide
        let newPixelWidth = Int(currentPixelWidth * scaleFactor)
        let newPixelHeight = Int(currentPixelHeight * scaleFactor)

        // Create a bitmap representation at exact pixel dimensions
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: newPixelWidth,
            pixelsHigh: newPixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        // Set the size to match pixels (1:1 ratio, no Retina scaling)
        bitmapRep.size = NSSize(width: newPixelWidth, height: newPixelHeight)

        // Draw into the bitmap
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        
        image.draw(in: NSRect(x: 0, y: 0, width: newPixelWidth, height: newPixelHeight),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        
        NSGraphicsContext.restoreGraphicsState()

        // Create NSImage from the bitmap
        let newImage = NSImage(size: NSSize(width: newPixelWidth, height: newPixelHeight))
        newImage.addRepresentation(bitmapRep)
        
        return newImage
    }
    
    private func writeImageToPasteboard(_ image: NSImage, imageData: Data, format: String) {
        pasteboard.clearContents()

        // Write ONLY the compressed format data (PNG or JPEG) to the pasteboard.
        // Do NOT include TIFF representation as that's uncompressed and will show
        // a much larger size in clipboard managers like Raycast.
        //
        // Most apps can read PNG/JPEG directly. The actual data size will match
        // what we save to disk.
        
        let item = NSPasteboardItem()

        if format == "jpg" {
            item.setData(imageData, forType: NSPasteboard.PasteboardType("public.jpeg"))
        } else {
            item.setData(imageData, forType: .png)
        }

        pasteboard.writeObjects([item])

        // Update our changeCount so we don't process our own change
        lastChangeCount = pasteboard.changeCount
    }
    
    private func showNotification(originalSize: String, newSize: String, originalBytes: Int, newBytes: Int, fileURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = "Image Optimized for Claude"
        content.body = "\(originalSize) → \(newSize)\n\(formatBytes(originalBytes)) → \(formatBytes(newBytes))"
        content.sound = nil // No sound
        content.categoryIdentifier = "resizedImageCategory"

        if let fileURL = fileURL {
            // Store the fileURL as a string in userInfo for later retrieval
            content.userInfo = ["fileURL": fileURL.absoluteString]
        }

        let uuidString = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuidString, content: content, trigger: nil) // trigger: nil for immediate delivery

        UNUserNotificationCenter.current().add(request) { (error) in
            if let error = error {
                print("Error delivering notification: \(error.localizedDescription)")
            }
        }
    }
    
    private func postHistoryEvent(message: String, fileURL: URL?) {
        var info: [String: Any] = ["message": message]
        if let fileURL = fileURL {
            info["fileURL"] = fileURL
        }
        NotificationCenter.default.post(
            name: .clipboardResizerHistoryEvent,
            object: nil,
            userInfo: info
        )
    }
    
    /// Resizes and compresses image to meet both PIXEL dimension and file size constraints
    private func resizeAndCompressPixels(_ image: NSImage,
                                         pixelWidth: CGFloat,
                                         pixelHeight: CGFloat,
                                         maxDimension: CGFloat,
                                         maxSize: Int) -> (image: NSImage, data: Data, format: String)? {
        var currentMaxDimension = maxDimension

        while currentMaxDimension >= 800 {
            let resized = resizeImagePixels(image, currentPixelWidth: pixelWidth, currentPixelHeight: pixelHeight, maxDimension: currentMaxDimension) ?? image

            if let result = compressImage(resized, maxSize: maxSize) {
                return (resized, result.data, result.format)
            }

            // Reduce dimension by 15% and try again
            currentMaxDimension *= 0.85
        }

        // Last resort: smallest size with aggressive compression
        let smallest = resizeImagePixels(image, currentPixelWidth: pixelWidth, currentPixelHeight: pixelHeight, maxDimension: 800) ?? image
        if let result = compressImage(smallest, maxSize: Int.max) {
            return (smallest, result.data, result.format)
        }

        return nil
    }

    /// Compresses image to target size, trying PNG first then JPEG with decreasing quality
    private func compressImage(_ image: NSImage, maxSize: Int) -> (data: Data, format: String)? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        // Try PNG first (good for screenshots/graphics)
        if let pngData = bitmap.representation(using: .png, properties: [:]),
           pngData.count <= maxSize {
            return (pngData, "png")
        }

        // Try JPEG with decreasing quality
        for quality in stride(from: 0.9, through: 0.4, by: -0.1) {
            if let jpegData = bitmap.representation(using: .jpeg,
                properties: [.compressionFactor: quality]),
               jpegData.count <= maxSize {
                return (jpegData, "jpg")
            }
        }

        // Return lowest quality JPEG as fallback
        if let jpegData = bitmap.representation(using: .jpeg,
            properties: [.compressionFactor: 0.3]) {
            return (jpegData, "jpg")
        }

        return nil
    }
    
    private func saveImageToDisk(imageData: Data, format: String, timestamp: String) -> URL? {
        guard let picturesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = picturesDir.appendingPathComponent("ClaudeResized", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Failed to create ClaudeResized folder: \(error)")
            return nil
        }
        let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        let filename = "ClaudeResized-\(safeTimestamp).\(format)"
        let fileURL = folder.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            print("⚠️ Failed to write resized image: \(error)")
            return nil
        }
    }
}

extension Notification.Name {
    static let clipboardResizerHistoryEvent = Notification.Name("ClipboardResizerHistoryEvent")
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let resizer = ClipboardImageResizer.shared
    private var menu: NSMenu?
    private struct HistoryEntry {
        let message: String
        let fileURL: URL?
    }
    private var history: [HistoryEntry] = []
    private let historyLimit = 5
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        registerNotificationCategories() // Call this to set up notification actions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in /* Handle authorization if needed */ }
        UNUserNotificationCenter.current().delegate = self // Set UNUserNotificationCenter delegate
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleHistoryEvent(_:)),
                                               name: .clipboardResizerHistoryEvent,
                                               object: nil)
        resizer.startMonitoring()
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "📐"
        }
        
        let menu = NSMenu()
        self.menu = menu
        rebuildMenu()
        statusItem.menu = menu
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        resizer.stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func rebuildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()
        
        let statusMenuItem = NSMenuItem(title: "Max: 1568px (Claude limit)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let historyHeader = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        historyHeader.isEnabled = false
        menu.addItem(historyHeader)
        
        if history.isEmpty {
            let emptyItem = NSMenuItem(title: "No activity yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            history.forEach { entry in
                let item = NSMenuItem(title: entry.message,
                                       action: entry.fileURL != nil ? #selector(openHistoryFile(_:)) : nil,
                                       keyEquivalent: "")
                item.target = self
                item.representedObject = entry.fileURL
                item.isEnabled = entry.fileURL != nil
                menu.addItem(item)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    
    @objc private func handleHistoryEvent(_ notification: Notification) {
        guard let message = notification.userInfo?["message"] as? String else { return }
        let fileURL = notification.userInfo?["fileURL"] as? URL
        history.insert(HistoryEntry(message: message, fileURL: fileURL), at: 0)
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
        DispatchQueue.main.async { [weak self] in
            self?.rebuildMenu()
        }
    }
    
    @objc private func openHistoryFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }

        guard let userInfo = response.notification.request.content.userInfo as? [String: Any],
              let filePath = userInfo["fileURL"] as? String,
              let fileURL = URL(string: filePath) else { return }

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == "openAction" {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func registerNotificationCategories() {
        let openAction = UNNotificationAction(identifier: "openAction", title: "Open", options: .foreground)
        let category = UNNotificationCategory(identifier: "resizedImageCategory", actions: [openAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Hide from dock (menu bar app only)
app.setActivationPolicy(.accessory)

app.run()
