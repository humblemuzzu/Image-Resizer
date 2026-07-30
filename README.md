# Claude Image Resizer

A lightweight macOS menu bar app that automatically resizes and compresses clipboard images to meet Claude's image requirements.

## The Problem

When working with AI coding assistants like **Claude Code** (Anthropic's CLI) or **OpenCode**, you'll frequently need to share screenshots—error messages, UI bugs, design references, etc. However, these tools have strict image limitations:

- **Visual token limit**: Claude sees images as 28×28 pixel patches, so an image costs
  `ceil(width/28) × ceil(height/28)` visual tokens, and that total has a budget.
- **Edge limit**: neither side may exceed the tier's maximum edge length.
- **File size limit**: the payload must fit a size cap that applies to the
  **base64-encoded** bytes, which are ~1.37× the raw file.

The token limit is the one that actually bites. A 1920×1080 screenshot is inside
1568px on both sides, yet it costs 2691 tokens and Claude shrinks it to 1456×819.
Enforcing "longest side ≤ 1568px" is not enough — see [Limits](#claudes-actual-limits).

If your screenshot exceeds these limits, you get errors like:

```
Image was too large. Double press esc to go back and try again with a smaller image.
```

This is frustrating when you're in the middle of debugging and just want to quickly paste a screenshot.

## The Solution

**Claude Image Resizer** runs silently in your menu bar and automatically:

1. Monitors your clipboard for new images
2. Computes the exact size Claude would resize it to, if any
3. Resizes to precisely that size, so the API resizes nothing and the image is
   resampled once instead of twice
4. Replaces the clipboard content with the optimized version
5. Sends a notification with the before/after stats

All of this happens in ~50ms—before you even paste.

## Claude's actual limits

| Resolution tier | Models | Max long edge | Max visual tokens |
| --------------- | ------ | ------------- | ----------------- |
| Standard | All models other than the below | 1568 px | 1568 |
| High-resolution | Claude 4.7 and later | 2576 px | 4784 |

An image costs `ceil(w/28) * ceil(h/28)` visual tokens. Claude finds the largest
aspect-preserving size satisfying **both** the edge limit and the token budget,
then pads the result up to the next multiple of 28 on the bottom and right.

**Practical ceilings — the largest images that need no resize at all:**

| shape | standard tier | high-resolution tier |
| ----- | ------------- | -------------------- |
| square | 1092×1092 | 1932×1932 |
| 16:9 | 1456×819 | 2576×1449 |

(The high-resolution square figure is derived from the formula: 1932 = 69×28 and
69² = 4761 ≤ 4784, whereas 2044 = 73×28 would cost 5329. `docs/claude-vision-spec.md`
§10 prints 2044×2044, which its own §1 formula contradicts.)

**Size limits apply to the base64-encoded payload, not the raw file.** Base64
encodes 3 bytes as 4 characters, so a 4.5 MB PNG is a 6 MB request body. The app
compares `ceil(raw/3)*4` against the cap. That cap is 10 MB on the Claude API
direct and on claude.ai, but 5 MB on Amazon Bedrock and Google Cloud; the app
holds the 5 MB figure because a payload that fits it is accepted everywhere.

**Not handled here:** a request containing more than 20 images gets a stricter
per-image cap of 2000 px. A clipboard utility sees one image at a time and cannot
know the shape of the eventual request, so this is not implementable in this app.
Keep such requests to 20 or fewer images, or pre-resize below 2000 px yourself.

## Features

- **Token-budget targeting**: resizes to exactly the size Claude would pick, so the
  API resizes nothing and text is resampled once rather than twice
- **28px alignment**: snaps output to the patch grid, so Claude pads nothing and no
  visual tokens are wasted
- **Resolution tier setting**: standard by default (valid on every model), switchable
  to high-resolution from the menu bar
- **Lossless first**: PNG at the target size; if the payload is still too big it
  reduces *dimensions* before it ever reduces quality, because heavy compression
  makes screenshot text hard to read
- **Base64-aware size check**: measures the encoded payload, not the raw bytes
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

`./build.sh` also produces a terminal version at `build/claude-image-resizer-script`:

```bash
./build.sh
./build/claude-image-resizer-script
```

Keep the terminal open. Press `Ctrl+C` to stop.

It is no longer runnable as `swift ClaudeImageResizer.swift`, because the limit
arithmetic now lives in `ClaudeImageResizer/ImageBudget.swift` and is shared with
the menu bar app. That is deliberate: when the two entry points each had their own
copy, the script drifted into measuring points instead of pixels and quietly passed
every Retina screenshot straight through.

### Verifying the maths

Both binaries take `--selftest`, which asserts every published example from
`docs/claude-vision-spec.md` and exits non-zero on any failure. `build.sh` runs it.

```bash
"./build/Claude Image Resizer.app/Contents/MacOS/ClaudeImageResizer" --selftest
```

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
- The operative budget (visual tokens and max edge) for the active tier
- The largest square and 16:9 images that pass through untouched
- The resolution tier picker (persisted across restarts)
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
│   Over the token budget, the edge limit, or the base64 cap? │
└────────┬────────────────────────────────────┬───────────────┘
         │ No                                  │ Yes
         ▼                                     ▼
┌─────────────────┐              ┌─────────────────────────────┐
│   Log & skip    │              │  Resize to the exact size    │
└─────────────────┘              │  Claude would pick, snapped  │
                                 │  to the 28px patch grid      │
                                 └──────────────┬──────────────┘
                                                │
                                                ▼
                                 ┌─────────────────────────────┐
                                 │  Encode (base64-aware)      │
                                 │  - PNG at the target size   │
                                 │  - then smaller dimensions  │
                                 │  - JPEG ≥0.75 as last resort│
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
- **Resize algorithm**: High-quality interpolation, never upscaling
- **Encoding strategy**: PNG at the target size; if the base64 payload is still over
  budget, dimensions come down in five steps before quality is touched, and JPEG
  never goes below quality 0.75. WebP would be preferable for text and Claude
  accepts it, but `NSBitmapImageRep` cannot encode WebP on macOS.
- **Retina handling**: Reads actual pixel dimensions from bitmap, not point dimensions

## Project Structure

```
ClaudeImageResizer/
├── ClaudeImageResizer.swift        # Standalone terminal version
├── ClaudeImageResizer/
│   ├── ImageBudget.swift           # All of Claude's limit arithmetic. Pure, no Cocoa.
│   ├── ImageBudgetSelfTest.swift   # --selftest assertions against the published numbers
│   ├── PixelResize.swift           # Pixel-exact bitmap handling, shared by both entry points
│   ├── main.swift                  # Menu bar app
│   └── Info.plist                  # App bundle metadata
├── build.sh                        # Builds both binaries, then runs --selftest
├── docs/claude-vision-spec.md      # The specification these numbers come from
└── README.md                       # This file
```

`ImageBudget.swift` is the only place a limit may be written down. Every constant in
it cites the section of `docs/claude-vision-spec.md` it comes from.

## Configuration

The resolution tier is the only runtime setting, and it lives in the menu bar. It
defaults to **standard**, which is the safe choice: an image sized for the standard
tier is accepted by every model, whereas a high-resolution-sized image is simply
resized again by anything older than Claude 4.7.

The limits themselves are in `ClaudeImageResizer/ImageBudget.swift`:

```swift
static let standard = VisionLimits(maxEdge: 1568, maxTokens: 1568)
static let highResolution = VisionLimits(maxEdge: 2576, maxTokens: 4784)
static let maxBase64Bytes = 5_000_000  // Bedrock/Vertex figure; valid everywhere
```

Changing one of those means changing what the app believes about Claude, so
`--selftest` will tell you if you have broken agreement with the spec.

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
- Check the image's token cost: `ceil(w/28) * ceil(h/28)`. Under 1568 on the standard
  tier means no resize is needed, whatever the pixel dimensions are.
- Check the menu bar history for activity logs

**Images resized twice / dimensions that do not match the menu**
- Make sure only one copy of the app is running. An older build left in
  `/Applications` and a newer one in `build/` will both rewrite the clipboard, and
  the image gets resampled twice.

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
