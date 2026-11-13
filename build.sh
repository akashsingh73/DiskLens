#!/bin/bash
# Builds DiskLens.app using only Apple's free Command Line Tools.
# No Xcode, no Apple ID, no developer account.
#
#   bash build.sh                   build into ./build/DiskLens.app
#   bash build.sh --install         build, then copy to /Applications
#   bash build.sh --install --open  build, install, and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DiskLens"
APP="build/$APP_NAME.app"
VERSION="1.1"
BUILD_NUMBER="2"
MIN_MACOS="14.0"
ARCH="$(uname -m)"

INSTALL=0
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) OPEN=1 ;;
    *) echo "Unknown option: $arg (use --install and/or --open)"; exit 1 ;;
  esac
done

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler isn't installed yet. Install Apple's free Command Line Tools:"
  echo "    xcode-select --install"
  echo "then run this script again."
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling $APP_NAME $VERSION for $ARCH (macOS $MIN_MACOS or later)…"
if ! xcrun swiftc \
  -O -wmo -swift-version 5 -parse-as-library \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos$MIN_MACOS" \
  -module-name "$APP_NAME" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  DiskLens/*.swift 2>&1 | tee build/compile.log; then
  echo
  echo "The build stopped. The full list of errors is in build/compile.log."
  exit 1
fi

# The app icon (drawn by Tools/make-icon.swift).
cp DiskLens/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.disklens.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Signing. With a code-signing certificate named "DiskLens Local" in your keychain (see the README,
# "Optional: keep Full Disk Access when you rebuild"), every build has the same identity, so macOS keeps
# Full Disk Access. Without one the app gets an ad-hoc signature: no setup and no account needed,
# but macOS sees each build as a new app. Set DISKLENS_SIGN_IDENTITY to use another certificate name.
SIGN_NAME="${DISKLENS_SIGN_IDENTITY:-DiskLens Local}"
SIGN_HASH="$({ security find-identity -p codesigning 2>/dev/null || true; } \
  | awk -v name="\"$SIGN_NAME\"" 'index($0, name) { print $2; exit }')"
STABLE_SIGNATURE=0
if [[ -n "$SIGN_HASH" ]]; then
  if codesign --force --sign "$SIGN_HASH" "$APP"; then
    STABLE_SIGNATURE=1
  else
    echo "Couldn't sign with the “$SIGN_NAME” certificate; using an ad-hoc signature instead."
  fi
fi
if [[ $STABLE_SIGNATURE -eq 0 ]]; then
  codesign --force --sign - "$APP"
  echo "Built $APP (ad-hoc signature)"
else
  echo "Built $APP (signed with “$SIGN_NAME”)"
fi

TARGET="$APP"
if [[ $INSTALL -eq 1 ]]; then
  # Replacing the app while it runs can crash the running copy, so quit it first.
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Quitting the running $APP_NAME…"
    pkill -x "$APP_NAME" || true
    sleep 1
  fi
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  TARGET="/Applications/$APP_NAME.app"
  echo "Installed $TARGET"
  if [[ $STABLE_SIGNATURE -eq 1 ]]; then
    echo "Full Disk Access carries over from earlier builds signed with “$SIGN_NAME”."
  else
    echo "Full Disk Access: with an ad-hoc signature each build counts as a new app. If DiskLens says"
    echo "access is off, remove it from System Settings > Privacy & Security > Full Disk Access"
    echo "(the minus button), add it again with the plus button, then reopen DiskLens."
    echo "To stop this, create a \"DiskLens Local\" signing certificate once (see the README)."
  fi
fi

if [[ $OPEN -eq 1 ]]; then
  open "$TARGET"
fi
