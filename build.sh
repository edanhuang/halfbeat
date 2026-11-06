#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/dist/歌词对齐.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swift tools/make_icons.swift "$PWD/assets"
iconutil -c icns "$PWD/assets/AppIcon.iconset" -o "$PWD/assets/AppIcon.icns"
# 先产出到临时文件再替换：dist 里的应用可能正在运行，直接写运行中的可执行文件会报 Text file busy。
# 同时编 arm64 与 x86_64，合并成通用二进制：Intel 与 Apple Silicon 都能直接跑。
SOURCES=(main.swift RuntimeBridge.swift LyricToastEvent.swift SuccessToast.swift StatusPanel.swift)
FRAMEWORKS=(-framework AppKit -framework ServiceManagement -framework QuartzCore)
for arch in arm64 x86_64; do
  xcrun swiftc "${SOURCES[@]}" -O -target "$arch-apple-macosx13.0" -o "$APP/Contents/MacOS/Halfbeat.$arch" "${FRAMEWORKS[@]}"
done
lipo -create "$APP/Contents/MacOS/Halfbeat.arm64" "$APP/Contents/MacOS/Halfbeat.x86_64" -output "$APP/Contents/MacOS/Halfbeat.new"
rm -f "$APP/Contents/MacOS/Halfbeat.arm64" "$APP/Contents/MacOS/Halfbeat.x86_64"
mv -f "$APP/Contents/MacOS/Halfbeat.new" "$APP/Contents/MacOS/Halfbeat"
cp bridge.js "$APP/Contents/Resources/"
cp assets/AppIcon.icns assets/MenuBarIcon.pdf "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Halfbeat</string>
<key>CFBundleIdentifier</key><string>local.lyricoffset.menubar</string>
<key>CFBundleName</key><string>Halfbeat</string>
<key>CFBundleDisplayName</key><string>歌词对齐</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.4</string>
<key>CFBundleVersion</key><string>22</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
