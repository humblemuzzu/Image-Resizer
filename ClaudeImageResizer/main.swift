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
    
    private static let tierDefaultsKey = "resolutionTier"

    /// Spec §2. Standard is the default because an image sized for it is accepted
    /// everywhere; a high-resolution-sized image is simply resized again by any
    /// model older than Claude 4.7.
    var tier: ResolutionTier {
        get { ResolutionTier(rawValue: UserDefaults.standard.string(forKey: Self.tierDefaultsKey) ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.tierDefaultsKey) }
    }

    /// Spec §9 prefers fewer pixels over lossy artefacts, so a PNG that misses the
    /// byte budget is retried at these fractions of the ideal size before quality is
    /// touched at all.
    private static let dimensionRetrySteps: [Double] = [1.0, 0.85, 0.72, 0.61, 0.52]

    /// Spec §9: heavy JPEG compression makes text hard to read, and screenshots of
    /// text are what this app exists to ship. The old ladder bottomed out at 0.3.
    private static let jpegQualitySteps: [Double] = [0.95, 0.9, 0.85, 0.8, 0.75]
    
    private init() {
        lastChangeCount = pasteboard.changeCount
    }
    
    func startMonitoring() {
        // Poll every 0.05 seconds (50ms) - fast enough to beat clipboard managers
        // This is still lightweight since we only check changeCount integer comparison
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        let limits = tier.limits
        print("✅ Claude Image Resizer started - \(tier.displayName): \(limits.maxTokens) visual tokens, \(limits.maxEdge)px max edge")
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

        // PIXEL dimensions, not points: on Retina, image.size reports half the
        // pixels Claude will actually be charged for.
        let source = pixelSize(of: image)

        let timestamp = dateFormatter.string(from: Date())
        let originalDimensions = "\(source.width)x\(source.height)"

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

        // Spec §4: the visual token budget is what binds, not the long edge. A
        // 1568x859 image is inside the edge limit on both sides and still costs 1736
        // tokens, so the API resizes it again unless we get there first.
        let limits = tier.limits
        let target = ImageBudget.targetSize(width: source.width, height: source.height, limits: limits)
        let originalTokens = ImageBudget.countImageTokens(width: source.width, height: source.height)
        // Spec §7: the size limit applies to the base64 payload, ~1.37x the raw bytes.
        let payloadFits = ImageBudget.base64Bytes(originalFileSize) <= ImageBudget.maxBase64Bytes

        if target == nil && payloadFits {
            let message = "[\(timestamp)] ✅ Within limits: \(originalDimensions) (\(formatBytes(originalFileSize)), \(originalTokens) tokens)"
            print(message)
            postHistoryEvent(message: message, fileURL: nil)
            return
        }

        // A nil target means the dimensions were fine and only the payload was over,
        // so there is nothing to scale down until an encode attempt says otherwise.
        guard let result = resizeAndEncode(image, target: target ?? source) else { return }

        writeImageToPasteboard(imageData: result.data, format: result.format)

        let newDimensions = "\(result.width)x\(result.height)"
        let newTokens = ImageBudget.countImageTokens(width: result.width, height: result.height)
        let savedURL = saveImageToDisk(imageData: result.data, format: result.format, timestamp: timestamp)

        let message = "[\(timestamp)] 📐 Optimized: \(originalDimensions) → \(newDimensions) (\(formatBytes(originalFileSize)) → \(formatBytes(result.data.count)), \(originalTokens) → \(newTokens) tokens)"
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
    
    private func writeImageToPasteboard(imageData: Data, format: String) {
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
    
    private struct Encoded {
        let data: Data
        let format: String
        let width: Int
        let height: Int
    }

    /// Produces the exact bytes to put on the pasteboard.
    ///
    /// Dimensions come down before quality does: spec §9 warns that lossy artefacts
    /// hurt the model and that heavy JPEG compression makes text hard to read. With
    /// the token budget capping a target at ~1.19 MP, the first PNG attempt wins for
    /// any real screenshot and everything below it is a genuine last resort.
    private func resizeAndEncode(_ image: NSImage, target: (width: Int, height: Int)) -> Encoded? {
        var smallestPNG: Encoded?

        for step in Self.dimensionRetrySteps {
            let candidate = ImageBudget.scaledDown(width: target.width, height: target.height, by: step)
            guard let bitmap = redraw(image, toPixelSize: candidate),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let encoded = Encoded(data: png, format: "png", width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            if ImageBudget.base64Bytes(png.count) <= ImageBudget.maxBase64Bytes {
                return encoded
            }
            smallestPNG = encoded
        }

        // WebP would be the better lossy format for text and spec §8 lists it as
        // supported, but NSBitmapImageRep.FileType has no WebP case on macOS and
        // ImageIO advertises no WebP destination either, so JPEG is the only lossy
        // option available without a new dependency.
        let smallest = ImageBudget.scaledDown(width: target.width, height: target.height,
                                              by: Self.dimensionRetrySteps.last ?? 1.0)
        if let bitmap = redraw(image, toPixelSize: smallest) {
            for quality in Self.jpegQualitySteps {
                guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                      ImageBudget.base64Bytes(jpeg.count) <= ImageBudget.maxBase64Bytes else { continue }
                print("⚠️ No PNG fit the base64 budget - falling back to lossy JPEG at quality \(quality) at \(bitmap.pixelsWide)x\(bitmap.pixelsHigh); text may soften")
                return Encoded(data: jpeg, format: "jpg", width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            }
        }

        if let smallestPNG {
            print("⚠️ Nothing fit the base64 budget, even at JPEG quality \(Self.jpegQualitySteps.last ?? 0) - shipping a lossless \(smallestPNG.width)x\(smallestPNG.height) PNG over budget rather than mangling the text further")
            return smallestPNG
        }

        print("⚠️ Could not encode the clipboard image at all - leaving the clipboard untouched")
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
        
        // The long edge is not the operative limit; the visual token budget is
        // (spec §4), so the menu states the budget and the sizes it works out to.
        let limits = resizer.tier.limits
        let squareCeiling = ImageBudget.resizedSize(width: limits.maxEdge * 2, height: limits.maxEdge * 2, limits: limits)
        let wideCeiling = ImageBudget.resizedSize(width: 3840, height: 2160, limits: limits)

        let budgetItem = NSMenuItem(title: "Budget: \(limits.maxTokens) visual tokens, \(limits.maxEdge)px max edge", action: nil, keyEquivalent: "")
        budgetItem.isEnabled = false
        menu.addItem(budgetItem)

        let ceilingItem = NSMenuItem(title: "Fits as-is: \(squareCeiling.width)x\(squareCeiling.height) square, \(wideCeiling.width)x\(wideCeiling.height) at 16:9", action: nil, keyEquivalent: "")
        ceilingItem.isEnabled = false
        menu.addItem(ceilingItem)

        menu.addItem(NSMenuItem.separator())

        let tierItem = NSMenuItem(title: "Resolution tier", action: nil, keyEquivalent: "")
        let tierMenu = NSMenu()
        for tier in ResolutionTier.allCases {
            let item = NSMenuItem(title: tier.displayName, action: #selector(selectTier(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tier.rawValue
            item.state = tier == resizer.tier ? .on : .off
            tierMenu.addItem(item)
        }
        tierItem.submenu = tierMenu
        menu.addItem(tierItem)

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
    
    @objc private func selectTier(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let tier = ResolutionTier(rawValue: rawValue) else { return }
        resizer.tier = tier
        rebuildMenu()
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

// Runs before anything touches NSApplication so the assertions can be checked in
// CI or from a terminal without a menu bar item appearing.
if CommandLine.arguments.contains("--selftest") {
    exit(ImageBudgetSelfTest.run() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Hide from dock (menu bar app only)
app.setActivationPolicy(.accessory)

app.run()
