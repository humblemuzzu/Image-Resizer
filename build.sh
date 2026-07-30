#!/bin/bash

# Build Claude Image Resizer for macOS
# Run this script from the ClaudeImageResizer directory

APP_NAME="Claude Image Resizer"
BUNDLE_ID="com.muzammil.claudeimageresizer"
OUTPUT_DIR="./build"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME..."

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Create app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp ClaudeImageResizer/Info.plist "$APP_PATH/Contents/"

# Sources shared by both entry points. ImageBudget.swift holds every number from
# docs/claude-vision-spec.md; nothing else is allowed to hardcode a limit.
SHARED_SOURCES=(
    ClaudeImageResizer/ImageBudget.swift
    ClaudeImageResizer/ImageBudgetSelfTest.swift
    ClaudeImageResizer/PixelResize.swift
)

# Compile Swift code
swiftc -O \
    -target arm64-apple-macosx12.0 \
    -o "$APP_PATH/Contents/MacOS/ClaudeImageResizer" \
    "${SHARED_SOURCES[@]}" \
    ClaudeImageResizer/main.swift \
    -framework Cocoa \
    -framework UserNotifications \
    || exit 1

# The standalone script shares the same budget maths, so it is built here rather
# than run with `swift ClaudeImageResizer.swift` - which would silently compile
# against nothing and drift, which is how it ended up measuring points.
swiftc -O \
    -target arm64-apple-macosx12.0 \
    -o "$OUTPUT_DIR/claude-image-resizer-script" \
    "${SHARED_SOURCES[@]}" \
    ClaudeImageResizer.swift \
    -framework Cocoa \
    || exit 1

# Check if build succeeded
if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "📍 App location: $APP_PATH"
    echo ""
    echo "To run the app:"
    echo "  open \"$APP_PATH\""
    echo ""
    echo "To add to Login Items (auto-start on boot):"
    echo "  1. Open System Preferences → General → Login Items"
    echo "  2. Click + and select \"$APP_PATH\""
    echo ""
    echo "Or via command line:"
    echo "  osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"$(pwd)/$APP_PATH\", hidden:false}'"
else
    echo "❌ Build failed!"
    exit 1
fi
