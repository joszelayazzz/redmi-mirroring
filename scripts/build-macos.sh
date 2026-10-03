#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
WORK="${REDMI_BUILD_WORK_DIR:-$ROOT/.build-work}"
mkdir -p "$BUILD" "$WORK"
STAGING_ROOT="$(mktemp -d "$WORK/macos-stage.XXXXXX")"
STAGING="$STAGING_ROOT/Redmi Mirroring.app"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
if [[ -f "$BUILD/Redmi Mirroring.app/Contents/Resources/AppIcon.icns" ]]; then
  cp "$BUILD/Redmi Mirroring.app/Contents/Resources/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"
fi
cd "$ROOT/macOS"
CLANG_MODULE_CACHE_PATH="$WORK/clang-cache" swift build --disable-sandbox --cache-path "$WORK/swift-cache" -c release --scratch-path "$WORK/swift-build"
cp "$WORK/swift-build/release/RedmiMirroring" "$STAGING/Contents/MacOS/RedmiMirroring"
cat > "$STAGING/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Redmi Mirroring</string>
<key>CFBundleDisplayName</key><string>Redmi Mirroring</string>
<key>CFBundleIdentifier</key><string>com.redmimirroring.mac</string>
<key>CFBundleExecutable</key><string>RedmiMirroring</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find and connect securely to your paired Redmi on your Wi-Fi network.</string>
<key>NSBonjourServices</key><array><string>_redmimirror._tcp</string></array>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Redmi pairing</string><key>CFBundleURLSchemes</key><array><string>redmimirror</string></array></dict></array>
</dict></plist>
PLIST
if [[ ! -f "$STAGING/Contents/Resources/AppIcon.icns" ]]; then
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  CLANG_MODULE_CACHE_PATH="$WORK/clang-cache" swift -module-cache-path "$WORK/clang-cache" "$ROOT/scripts/make-icon.swift" "$WORK/AppIcon.png"
  for dimension in 16 32 128 256 512; do
    sips -z "$dimension" "$dimension" "$WORK/AppIcon.png" --out "$ICONSET/icon_${dimension}x${dimension}.png" >/dev/null
    retina=$((dimension * 2))
    sips -z "$retina" "$retina" "$WORK/AppIcon.png" --out "$ICONSET/icon_${dimension}x${dimension}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGING/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --identifier com.redmimirroring.mac "$STAGING"
if [[ -d "$BUILD/Redmi Mirroring.app" ]]; then
  mv "$BUILD/Redmi Mirroring.app" "$STAGING_ROOT/Previous.app"
fi
mv "$STAGING" "$BUILD/Redmi Mirroring.app"
print "Built $BUILD/Redmi Mirroring.app"
