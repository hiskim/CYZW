#!/bin/sh
set -eu

# This is intentionally a WebKit-only macOS build. It does not invoke the
# legacy Cocos Xcode project, so it cannot alter the iOS/Cocos configuration.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
GAME_ROOT="$REPO_ROOT/ios-cocos/cocos-project"
ENGINE_HOST_ROOT="$REPO_ROOT/ios/EngineHost"

BUILD_ROOT=${IOS2_MAC_BUILD_ROOT:-$REPO_ROOT/ios-cocos/build/macos-webkit}
OUTPUT_DIR=${IOS2_OUTPUT_DIR:-$REPO_ROOT/ios-cocos/build}
APP_NAME=${IOS2_MAC_APP_NAME:-IOS2-WebKit}
DMG_NAME=${IOS2_DMG_NAME:-$APP_NAME}
DEPLOYMENT_TARGET=${IOS2_MACOS_DEPLOYMENT_TARGET:-12.0}
MAC_ARCHS=${IOS2_MAC_ARCHS:-"arm64 x86_64"}
APP_PATH="$BUILD_ROOT/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"

say() {
    printf '%s\n' "ios2-macos: $*"
}

die() {
    printf '%s\n' "ios2-macos: $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || die "required file not found: $1"
}

require_dir() {
    [ -d "$1" ] || die "required directory not found: $1"
}

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
    if [ -e "$BUILD_ROOT" ]; then
        rm -rf -- "$BUILD_ROOT"
        say "removed build directory: $BUILD_ROOT"
    fi
}

write_info_plist() {
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
}

build_binary() {
    BIN_DIR="$BUILD_ROOT/bin"
    SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
    mkdir -p "$BIN_DIR"

    for ARCH in $MAC_ARCHS; do
        case "$ARCH" in
            arm64|x86_64) ;;
            *) die "unsupported macOS architecture: $ARCH" ;;
        esac
        say "building WebKit Shell ($ARCH)"
        xcrun swiftc \
            -sdk "$SDK_PATH" \
            -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
            -O \
            "$ENGINE_HOST_ROOT"/*.swift \
            "$SCRIPT_DIR"/*.swift \
            -framework AppKit \
            -framework SwiftUI \
            -framework WebKit \
            -framework UniformTypeIdentifiers \
            -o "$BIN_DIR/$APP_NAME-$ARCH"
    done

    set -- $MAC_ARCHS
    if [ "$#" -eq 1 ]; then
        ditto "$BIN_DIR/$APP_NAME-$1" "$APP_PATH/Contents/MacOS/$APP_NAME"
    else
        lipo -create "$BIN_DIR/$APP_NAME-"* -output "$APP_PATH/Contents/MacOS/$APP_NAME"
    fi
}

copy_web_runtime() {
    RUNTIME_PATH="$APP_PATH/Contents/Resources/WebRuntime"
    say "copying bundled WebKit runtime"
    mkdir -p "$RUNTIME_PATH"
    ditto "$GAME_ROOT/src" "$RUNTIME_PATH/src"
    ditto "$GAME_ROOT/assets" "$RUNTIME_PATH/assets"
    mkdir -p "$RUNTIME_PATH/jsb-adapter"
    ditto "$GAME_ROOT/jsb-adapter/game-defines.js" "$RUNTIME_PATH/jsb-adapter/game-defines.js"
    mkdir -p "$APP_PATH/Contents/Resources/shared"
    ditto "$GAME_ROOT/src/design-tokens.css" "$APP_PATH/Contents/Resources/shared/design-tokens.css"
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
    rm -rf -- "$APP_PATH"
    mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
    write_info_plist
    build_binary
    copy_web_runtime
    validate_app
    say "app: $APP_PATH"
    du -sh "$APP_PATH"
}

sign_app() {
    SIGNING_IDENTITY=${IOS2_MAC_SIGNING_IDENTITY:--}
    if [ "$SIGNING_IDENTITY" = "none" ]; then
        say "skipping code signing"
        return
    fi
    say "signing app: $SIGNING_IDENTITY"
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

create_dmg() {
    STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ios2-webkit-dmg.XXXXXX")
    trap 'rm -rf -- "$STAGING_DIR"' EXIT HUP INT TERM
    ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
    ln -s /Applications "$STAGING_DIR/Applications"

    mkdir -p "$OUTPUT_DIR"
    rm -f -- "$DMG_PATH"
    say "creating DMG: $DMG_PATH"
    hdiutil create -volname "$DMG_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
    hdiutil verify "$DMG_PATH"
    rm -rf -- "$STAGING_DIR"
    trap - EXIT HUP INT TERM
    say "dmg: $DMG_PATH"
    du -sh "$DMG_PATH"
}

validate_inputs

case "${1:-dmg}" in
    clean)
        clean_build_artifacts
        ;;
    app)
        build_app
        sign_app
        ;;
    dmg)
        build_app
        sign_app
        create_dmg
        ;;
    run)
        build_app
        sign_app
        open -n "$APP_PATH"
        ;;
    *)
        printf '%s\n' "usage: $0 [clean|app|dmg|run]" >&2
        exit 2
        ;;
esac
