#!/bin/bash
set -euo pipefail

APP_NAME="ZoomIt for Mac"
BUNDLE_ID="com.zoomit.mac"
APP_DIR="/Applications/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🔨 Building ZoomIt for Mac (release)..."
swift build -c release --quiet

EXECUTABLE=$(swift build -c release --show-bin-path)/ZoomItForMacApp

if [ ! -f "$EXECUTABLE" ]; then
    echo "❌ Build failed — executable not found."
    exit 1
fi

echo "📦 Creating app bundle at ${APP_DIR}..."

# Remove old install if present
if [ -d "$APP_DIR" ]; then
    echo "   Removing previous installation..."
    rm -rf "$APP_DIR"
fi

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/ZoomItForMacApp"

cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>ZoomItForMacApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "✅ Installed to ${APP_DIR}"
echo ""
echo "   To launch:  open '/Applications/${APP_NAME}.app'"
echo "   To remove:  rm -rf '/Applications/${APP_NAME}.app'"
echo ""
echo "⚠️  On first launch, macOS will ask for Accessibility and"
echo "   Screen Recording permissions in System Settings."
