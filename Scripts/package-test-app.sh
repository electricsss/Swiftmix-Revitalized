#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
APP_NAME="SwiftMix Nominal Lock"
BUNDLE_NAME="$APP_NAME.app"
DIST_DIR="$PROJECT_DIR/dist"
STAGE_DIR="$PROJECT_DIR/.build/package-stage"
ARM_BUILD="$PROJECT_DIR/.build/package-arm64"
X86_BUILD="$PROJECT_DIR/.build/package-x86_64"
APP_DIR="$STAGE_DIR/$BUNDLE_NAME"
ZIP_PATH="$DIST_DIR/SwiftMix-Nominal-Lock-macOS-test.zip"

rm -rf "$STAGE_DIR" "$ARM_BUILD" "$X86_BUILD"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"

swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --build-path "$ARM_BUILD"
swift build --package-path "$PROJECT_DIR" -c release --arch x86_64 --build-path "$X86_BUILD"

ARM_BINARY="$ARM_BUILD/arm64-apple-macosx/release/SwiftMixNominal"
X86_BINARY="$X86_BUILD/x86_64-apple-macosx/release/SwiftMixNominal"
if [ ! -x "$ARM_BINARY" ] || [ ! -x "$X86_BINARY" ]; then
    echo "Expected release binaries were not produced." >&2
    exit 1
fi

/usr/bin/lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$APP_DIR/Contents/MacOS/SwiftMixNominal"
chmod 755 "$APP_DIR/Contents/MacOS/SwiftMixNominal"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"

/usr/bin/codesign --force --deep --sign - --identifier com.electric.swiftmix-nominal "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
/usr/bin/lipo -info "$APP_DIR/Contents/MacOS/SwiftMixNominal"

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
cp "$PROJECT_DIR/Packaging/TESTING.md" "$DIST_DIR/TESTING.md"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
)

printf '\nPackaged test build:\n  %s\n  %s\n  %s\n' "$ZIP_PATH" "$ZIP_PATH.sha256" "$DIST_DIR/TESTING.md"
printf '\nThis is ad-hoc signed, not Developer ID notarized. See Packaging/TESTING.md.\n'
