# Claude Image Resizer

A lightweight macOS menu bar app that automatically resizes and compresses clipboard images to meet Claude's image requirements.

## The Problem

When working with AI coding assistants like **Claude Code** (Anthropic's CLI) or **OpenCode**, you'll frequently need to share screenshots—error messages, UI bugs, design references, etc. However, these tools have strict image limitations:

- **Dimension limit**: Images must be ≤1568px on the longest side for optimal processing
- **File size limit**: Images must be under 5MB

If your screenshot exceeds these limits, you get errors like:

```
Image was too large. Double press esc to go back and try again with a smaller image.
```

This is frustrating when you're in the middle of debugging and just want to quickly paste a screenshot.

## The Solution

**Claude Image Resizer** runs silently in your menu bar and automatically:

1. Monitors your clipboard for new images
2. Detects if an image exceeds Claude's limits (1568px or 5MB)
3. Resizes and compresses the image while preserving quality
4. Replaces the clipboard content with the optimized version
5. Sends a notification with the before/after stats

All of this happens in ~50ms—before you even paste.

## Features

- **Automatic resizing**: Keeps images ≤1568px (Claude's optimal dimension)
- **Smart compression**: Tries PNG first, falls back to JPEG with quality reduction if needed
- **File size targeting**: Ensures images stay under 5MB
- **Native macOS**: Built with Swift/Cocoa, runs as a lightweight menu bar app
- **History tracking**: View recent resize activity from the menu bar
- **Saved copies**: Resized images are saved to `~/Pictures/ClaudeResized/` for reference
- **Notifications**: Get notified when images are resized with before/after dimensions and file sizes

## Installation

### Prerequisites

- macOS 12.0+ (Monterey or later)
- Xcode Command Line Tools:
  ```bash
  xcode-select --install
  ```

### Option 1: Build the Menu Bar App (Recommended)

```bash
# Clone the repository
git clone https://github.com/humblemuzzu/Image-Resizer.git
cd Image-Resizer

# Build the app
chmod +x build.sh
./build.sh

# Run the app
open "build/Claude Image Resizer.app"
```

### Option 2: Run the Script Directly

For quick testing without building:

```bash
swift ClaudeImageResizer.swift
```

Keep the terminal open. Press `Ctrl+C` to stop.

### Auto-Start on Login

To have the app start automatically when you log in:

**Via System Settings:**
1. Open **System Settings → General → Login Items**
2. Click **+** and select the built app from `build/Claude Image Resizer.app`

**Via Terminal:**
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'$(pwd)'/build/Claude Image Resizer.app", hidden:false}'
```

## Usage

Once running, the app works completely automatically:

1. **Take a screenshot** (Cmd+Shift+4, etc.) or copy any image
2. **The app detects it** and checks if it needs resizing
3. **If over limits**, it resizes/compresses and updates your clipboard
4. **Paste normally** (Cmd+V) into Claude Code, OpenCode, or any app

### Menu Bar

Click the 📐 icon in your menu bar to see:
- Current max dimension setting (1568px)
- Recent activity log (last 5 operations)
- Quit option

### Notifications

When an image is resized, you'll see a notification showing:
- Original dimensions → New dimensions
- Original file size → New file size

Click the notification to open the saved image file.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Clipboard Monitor                        │
│                  (polls every 50ms)                         │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              Is there a new image?                          │
│         (checks pasteboard changeCount)                     │
└─────────────────────┬───────────────────────────────────────┘
                      │ Yes
                      ▼
┌─────────────────────────────────────────────────────────────┐
│     Check PIXEL dimensions (not points!)                    │
│     - Handles Retina displays correctly                     │
│     - Reads actual bitmap pixel size                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│   Needs resize? (>1568px or >5MB)                           │
└────────┬────────────────────────────────────┬───────────────┘
         │ No                                  │ Yes
         ▼                                     ▼
┌─────────────────┐              ┌─────────────────────────────┐
│   Log & skip    │              │  Resize to fit 1568px       │
└─────────────────┘              │  (high-quality interpolation)│
                                 └──────────────┬──────────────┘
                                                │
                                                ▼
                                 ┌─────────────────────────────┐
                                 │  Compress if needed         │
                                 │  - Try PNG first            │
                                 │  - Fall back to JPEG        │
                                 │  - Reduce quality if >5MB   │
                                 └──────────────┬──────────────┘
                                                │
                                                ▼
                                 ┌─────────────────────────────┐
                                 │  Write back to clipboard    │
                                 │  Save to ~/Pictures/        │
                                 │  Show notification          │
                                 └─────────────────────────────┘
```

### Technical Details

- **Polling interval**: 50ms (lightweight—only compares an integer)
- **Resize algorithm**: High-quality Lanczos interpolation
- **Compression strategy**: PNG for screenshots/graphics, JPEG (0.9→0.3 quality) for photos
- **Retina handling**: Reads actual pixel dimensions from bitmap, not point dimensions

## Project Structure

```
ClaudeImageResizer/
├── ClaudeImageResizer.swift    # Standalone script version (~100 lines)
├── ClaudeImageResizer/
│   ├── main.swift              # Full menu bar app (~470 lines)
│   └── Info.plist              # App bundle metadata
├── build.sh                    # Build script for creating .app bundle
├── README.md                   # This file
└── logs.md                     # Development notes
```

## Configuration

The default settings are optimized for Claude, but you can modify them in the source:

```swift
// In ClaudeImageResizer/main.swift
let maxDimension: CGFloat = 1568  // Max pixels on longest side
let maxFileSize: Int = 5_000_000  // Max file size in bytes (5MB)
```

For the simple script version:
```swift
// In ClaudeImageResizer.swift
let MAX_DIMENSION: CGFloat = 1568
```

## Comparison with Alternatives

| Feature | Claude Image Resizer | Clop | Manual Resize |
|---------|---------------------|------|---------------|
| Price | Free | Free/Paid | Free |
| Auto-resize to specific px | ✅ | ❌ (% or DPI only) | ❌ |
| Clipboard monitoring | ✅ | ✅ | ❌ |
| File size compression | ✅ | ✅ | ❌ |
| Claude-optimized defaults | ✅ | ❌ | ❌ |
| Lightweight | ✅ (~500 lines) | ❌ (full app) | N/A |
| Video support | ❌ | ✅ | N/A |

## Troubleshooting

**App won't start**
- Ensure Xcode CLI tools are installed: `xcode-select --install`
- Check if the app is blocked: System Settings → Privacy & Security

**Images not resizing**
- Verify the image exceeds 1568px (check with Preview → Tools → Adjust Size)
- Check the menu bar history for activity logs

**Clipboard not updating**
- Some apps use private clipboard formats; standard image copies should work
- Try copying the image from Preview or another standard app

**High CPU usage**
- The 50ms polling is very lightweight, but you can increase the interval in `main.swift`

## License

MIT License - Use it however you want.

## Contributing

Issues and PRs welcome! This is a simple utility—feel free to fork and customize for your needs.

---

Built to make image sharing with Claude Code and OpenCode seamless.
