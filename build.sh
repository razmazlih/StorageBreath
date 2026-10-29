#!/bin/zsh
set -eu
cd "${0:A:h}"
DEST="$PWD/build/StorageBreath.app"
STAGE=$(mktemp -d /private/tmp/storagebreath-build.XXXXXX)
APP="$STAGE/StorageBreath.app"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/module-cache"
PROJECT_ROOT="$PWD"
mkdir -p "$STAGE/Sources"
for swift_source in App.swift StorageEngine.swift VisualEffects.swift CloudEngine.swift CloudView.swift ProtectionStore.swift FileControls.swift DeepScanEngine.swift Dashboard.swift AIExchange.swift AIFlow.swift InventoryDatabase.swift PermissionsSetup.swift; do
    cp "$PROJECT_ROOT/$swift_source" "$STAGE/Sources/$swift_source"
done
(
    cd "$STAGE/Sources"
    swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$PROJECT_ROOT/build/module-cache" App.swift StorageEngine.swift VisualEffects.swift CloudEngine.swift CloudView.swift ProtectionStore.swift FileControls.swift DeepScanEngine.swift Dashboard.swift AIExchange.swift AIFlow.swift InventoryDatabase.swift PermissionsSetup.swift -o "$APP/Contents/MacOS/StorageBreath" -framework SwiftUI -framework AppKit
)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>StorageBreath</string><key>CFBundleIdentifier</key><string>local.razmaz.storagebreath</string><key>CFBundleName</key><string>מקום לנשום</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string מקום לנשום" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto --norsrc --noextattr "$APP" "$DEST"
echo "$DEST"
