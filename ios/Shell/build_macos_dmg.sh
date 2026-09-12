#!/bin/sh
set -eu

# WebKit-only macOS build. Independent from the legacy iOS/Cocos projects.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
GAME_ROOT="$REPO_ROOT/ios-cocos/cocos-project"
ENGINE_HOST_ROOT="$REPO_ROOT/ios/EngineHost"
BUILD_ROOT=${IOS2_MAC_BUILD_ROOT:-$REPO_ROOT/ios-cocos/build/macos-webkit}
OUTPUT_DIR=${IOS2_OUTPUT_DIR:-$REPO_ROOT/ios-cocos/build}
APP_NAME=${IOS2_MAC_APP_NAME:-IOS2-WebKit}
DMG_NAME=${IOS2_DMG_NAME:-$APP_NAME}
# 与 IOS2-Mac.xcodeproj 保持一致：MACOSX_DEPLOYMENT_TARGET = 26.0、ARCHS = arm64 x86_64。
# macOS 26 SDK 仍带 x86_64 切片，实测 -target x86_64-apple-macos26.0 可正常编译链接。
# 只编本机架构用 IOS2_MAC_ARCHS=arm64 覆盖可省一半时间。
DEPLOYMENT_TARGET=${IOS2_MACOS_DEPLOYMENT_TARGET:-26.0}
MAC_ARCHS=${IOS2_MAC_ARCHS:-"arm64 x86_64"}
BUILD_CONFIGURATION=${IOS2_MAC_CONFIGURATION:-release}
APP_PATH="$BUILD_ROOT/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"

say() { printf '%s\n' "ios2-macos: $*"; }
die() { printf '%s\n' "ios2-macos: $*" >&2; exit 1; }
require_file() { [ -f "$1" ] || die "required file not found: $1"; }
require_dir() { [ -d "$1" ] || die "required directory not found: $1"; }

validate_inputs() {
    require_file "$SCRIPT_DIR/MainApp.swift"
    require_file "$SCRIPT_DIR/MacWebKitGameWindow.swift"
    require_dir "$ENGINE_HOST_ROOT"
    require_dir "$GAME_ROOT/src"
    require_dir "$GAME_ROOT/assets"
    require_file "$GAME_ROOT/src/ios2-web-index.html"
    require_file "$GAME_ROOT/src/ios2-web-cocos2d.js"
    require_file "$GAME_ROOT/src/ios2-web-boot.js"
    require_file "$GAME_ROOT/src/settings.b2e22.js"
    require_file "$GAME_ROOT/jsb-adapter/game-defines.js"
}

clean_build_artifacts() {
    case "$BUILD_ROOT" in
        ""|/|"$REPO_ROOT"|"$GAME_ROOT") die "refusing to clean unsafe build path: '$BUILD_ROOT'" ;;
    esac
    [ ! -e "$BUILD_ROOT" ] || { rm -rf -- "$BUILD_ROOT"; say "removed build directory: $BUILD_ROOT"; }
    [ ! -e "$DMG_PATH" ] || { rm -f -- "$DMG_PATH"; say "removed DMG: $DMG_PATH"; }
}

copy_web_runtime() {
    RUNTIME_PATH="$APP_PATH/Contents/Resources/WebRuntime"
    say "copying bundled WebKit runtime"
    mkdir -p "$RUNTIME_PATH"
    ditto "$GAME_ROOT/src" "$RUNTIME_PATH/src"
    ditto "$GAME_ROOT/assets" "$RUNTIME_PATH/assets"
    mkdir -p "$RUNTIME_PATH/jsb-adapter"
    ditto "$GAME_ROOT/jsb-adapter/game-defines.js" "$RUNTIME_PATH/jsb-adapter/game-defines.js"
}

validate_app() {
    require_file "$APP_PATH/Contents/MacOS/$APP_NAME"
    require_file "$APP_PATH/Contents/Info.plist"
    require_file "$APP_PATH/Contents/Resources/WebRuntime/src/ios2-web-index.html"
    require_file "$APP_PATH/Contents/Resources/WebRuntime/src/ios2-web-cocos2d.js"
    require_file "$APP_PATH/Contents/Resources/WebRuntime/src/ios2-web-boot.js"
    require_file "$APP_PATH/Contents/Resources/WebRuntime/src/settings.b2e22.js"
    require_file "$APP_PATH/Contents/Resources/WebRuntime/jsb-adapter/game-defines.js"
    require_dir "$APP_PATH/Contents/Resources/WebRuntime/assets/internal"
    plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
}

build_app() {
    validate_inputs
    rm -rf -- "$APP_PATH"
    mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
    cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.xyzw.ios2.webkit.macos</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>LSMultipleInstancesProhibited</key><false/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

    BIN_DIR="$BUILD_ROOT/bin"
    SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
    mkdir -p "$BIN_DIR"
    case "$BUILD_CONFIGURATION" in
        debug) SWIFT_BUILD_FLAGS="-Onone -g" ;;
        release) SWIFT_BUILD_FLAGS="-O" ;;
        *) die "unsupported macOS build configuration: $BUILD_CONFIGURATION" ;;
    esac

    for ARCH in $MAC_ARCHS; do
        case "$ARCH" in arm64|x86_64) ;; *) die "unsupported macOS architecture: $ARCH" ;; esac
        say "building WebKit Shell ($ARCH)"
        xcrun swiftc -sdk "$SDK_PATH" -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
            $SWIFT_BUILD_FLAGS "$ENGINE_HOST_ROOT"/*.swift "$SCRIPT_DIR"/*.swift \
            -framework AppKit -framework SwiftUI -framework WebKit -framework UniformTypeIdentifiers \
            -o "$BIN_DIR/$APP_NAME-$ARCH"
    done

    set -- $MAC_ARCHS
    if [ "$#" -eq 1 ]; then
        ditto "$BIN_DIR/$APP_NAME-$1" "$APP_PATH/Contents/MacOS/$APP_NAME"
    elif [ "$#" -eq 2 ]; then
        lipo -create "$BIN_DIR/$APP_NAME-$1" "$BIN_DIR/$APP_NAME-$2" -output "$APP_PATH/Contents/MacOS/$APP_NAME"
    else
        die "macOS universal build supports one or two architectures: $MAC_ARCHS"
    fi
    if [ "$BUILD_CONFIGURATION" = "debug" ]; then
        xcrun dsymutil "$APP_PATH/Contents/MacOS/$APP_NAME" -o "$BUILD_ROOT/$APP_NAME.app.dSYM"
    fi
    copy_web_runtime
    validate_app
    say "app: $APP_PATH"
    du -sh "$APP_PATH"
}

sign_app() {
    SIGNING_IDENTITY=${IOS2_MAC_SIGNING_IDENTITY:--}
    [ "$SIGNING_IDENTITY" = "none" ] && { say "skipping code signing"; return; }
    codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

create_dmg() {
    STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ios2-webkit-dmg.XXXXXX")
    trap 'rm -rf -- "$STAGING_DIR"' EXIT HUP INT TERM
    ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
    ln -s /Applications "$STAGING_DIR/Applications"
    mkdir -p "$OUTPUT_DIR"
    rm -f -- "$DMG_PATH"
    hdiutil create -volname "$DMG_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
    hdiutil verify "$DMG_PATH"
    rm -rf -- "$STAGING_DIR"
    trap - EXIT HUP INT TERM
    say "dmg: $DMG_PATH"
    du -sh "$DMG_PATH"
}

case "${1:-dmg}" in
    clean) clean_build_artifacts ;;
    app) build_app; sign_app ;;
    dmg) build_app; sign_app; create_dmg ;;
    run) build_app; sign_app; open -n "$APP_PATH" ;;
    debug|run-debug) BUILD_CONFIGURATION=debug; build_app; sign_app; open -n "$APP_PATH"; say "debug app launched; attach Xcode to process: $APP_NAME" ;;
    *) printf '%s\n' "usage: $0 [clean|app|dmg|run|debug|run-debug]" >&2; exit 2 ;;
esac
