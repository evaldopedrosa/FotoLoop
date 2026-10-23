#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release "$@"

APP="$ROOT/../Aplicativo/FotoLoop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
cp "$BIN_DIR/FotoLoop" "$APP/Contents/MacOS/FotoLoop"
cp "$ROOT/../Design/FotoLoop.icns" "$APP/Contents/Resources/FotoLoop.icns"
cp "$ROOT/../LICENSE" "$APP/Contents/Resources/LICENSE.txt"
chmod 644 "$APP/Contents/Resources/FotoLoop.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FotoLoop</string>
  <key>CFBundleIdentifier</key><string>com.evaldopedrosa.fotoloop</string>
  <key>CFBundleName</key><string>FotoLoop</string>
  <key>CFBundleIconFile</key><string>FotoLoop.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>0.4.0</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "Aplicativo criado em: $APP"
