#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
IOS2_ROOT="$REPO_ROOT/ios-cocos"
PROJECT_ROOT="$IOS2_ROOT/cocos-project"

CONFIGURATION=${IOS2_MAC_CONFIGURATION:-Release}
MACOS_DEPLOYMENT_TARGET=${IOS2_MACOS_DEPLOYMENT_TARGET:-12.0}
MAC_ARCHS=${IOS2_MAC_ARCHS:-$(uname -m)}
DERIVED_DATA=${IOS2_MAC_DERIVED_DATA:-$IOS2_ROOT/build/macos-dmg-derived}
OUTPUT_DIR=${IOS2_OUTPUT_DIR:-$IOS2_ROOT/build}
APP_NAME=${IOS2_MAC_APP_NAME:-IOS2-desktop}
DMG_NAME=${IOS2_DMG_NAME:-$APP_NAME}
DMG_VOLUME_NAME=${IOS2_DMG_VOLUME_NAME:-IOS2}
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_EXECUTABLE=${IOS2_MAC_EXECUTABLE_NAME:-$APP_NAME}
DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"

print_usage() {
    cat <<EOF
usage: $0 [clean|app|dmg]

Builds the standalone macOS SwiftUI Shell and optionally packages it as a DMG.

Environment overrides:
  IOS2_MAC_CONFIGURATION       Xcode configuration (default: Release)
  IOS2_MACOS_DEPLOYMENT_TARGET macOS deployment target (default: 12.0)
  IOS2_MAC_ARCHS               architectures, e.g. "arm64" or "arm64 x86_64"
  IOS2_MAC_DERIVED_DATA        derived data directory
  IOS2_OUTPUT_DIR              output directory for the DMG
  IOS2_MAC_SIGNING_IDENTITY    codesign identity; default is ad-hoc signing (-)
  IOS2_MAC_APP_NAME            app bundle name (default: IOS2-desktop)
  IOS2_MAC_EXECUTABLE_NAME     executable name inside the app bundle
  IOS2_DMG_NAME                DMG filename without .dmg
  IOS2_DMG_VOLUME_NAME         mounted DMG volume name
EOF
}

require_file() {
    if [ ! -f "$1" ]; then
        echo "ios2: required file not found: $1" >&2
        exit 1
    fi
}

require_directory() {
    if [ ! -d "$1" ]; then
        echo "ios2: required directory not found: $1" >&2
        exit 1
    fi
}

clean_build_artifacts() {
    case "$DERIVED_DATA" in
        ""|/|"$REPO_ROOT"|"$IOS2_ROOT")
            echo "ios2: refusing to clean unsafe derived-data path: '$DERIVED_DATA'" >&2
            exit 2
            ;;
    esac

    if [ -e "$DERIVED_DATA" ]; then
        rm -rf -- "$DERIVED_DATA"
        echo "ios2: removed derived data: $DERIVED_DATA"
    else
        echo "ios2: derived data not found: $DERIVED_DATA"
    fi

    if [ -e "$DMG_PATH" ]; then
        rm -f -- "$DMG_PATH"
        echo "ios2: removed DMG: $DMG_PATH"
    else
        echo "ios2: DMG not found: $DMG_PATH"
    fi
}

build_app() {
    require_file "$SCRIPT_DIR/MainApp.swift"
    require_file "$REPO_ROOT/ios/EngineHost/EngineHost.swift"

    BUILD_BIN_DIR="$DERIVED_DATA/Build/Intermediates/Shell"
    mkdir -p "$BUILD_BIN_DIR" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

    echo "ios2: building standalone macOS Shell ($MAC_ARCHS)"
    for ARCH in $MAC_ARCHS; do
        case "$ARCH" in
            arm64|x86_64) ;;
            *)
                echo "ios2: unsupported macOS architecture: $ARCH" >&2
                exit 2
                ;;
        esac

        ARCH_DIR="$BUILD_BIN_DIR/$ARCH"
        mkdir -p "$ARCH_DIR"
        xcrun swiftc \
            -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
            -target "$ARCH-apple-macos$MACOS_DEPLOYMENT_TARGET" \
            -O \
            "$REPO_ROOT"/ios/EngineHost/*.swift \
            "$SCRIPT_DIR"/*.swift \
            -framework SwiftUI \
            -framework AppKit \
            -framework UniformTypeIdentifiers \
            -o "$ARCH_DIR/$APP_EXECUTABLE"
    done

    if [ "$(printf '%s\n' $MAC_ARCHS | wc -l | tr -d ' ')" -eq 1 ]; then
        ditto "$BUILD_BIN_DIR/$MAC_ARCHS/$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
    else
        lipo -create "$BUILD_BIN_DIR"/*/"$APP_EXECUTABLE" -output "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
    fi

    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    if [ ! -f "$INFO_PLIST" ]; then
        plutil -create xml1 "$INFO_PLIST"
    fi
    plutil -replace CFBundleDevelopmentRegion -string en "$INFO_PLIST"
    plutil -replace CFBundleExecutable -string "$APP_EXECUTABLE" "$INFO_PLIST"
    plutil -replace CFBundleIdentifier -string com.xyzw.ios2.shell.macos "$INFO_PLIST"
    plutil -replace CFBundleInfoDictionaryVersion -string 6.0 "$INFO_PLIST"
    plutil -replace CFBundleName -string "$APP_NAME" "$INFO_PLIST"
    plutil -replace CFBundlePackageType -string APPL "$INFO_PLIST"
    plutil -replace CFBundleShortVersionString -string 1.0 "$INFO_PLIST"
    plutil -replace CFBundleVersion -string 1 "$INFO_PLIST"
    plutil -replace LSMinimumSystemVersion -string "$MACOS_DEPLOYMENT_TARGET" "$INFO_PLIST"
    plutil -replace NSHighResolutionCapable -bool YES "$INFO_PLIST"

    SIGNING_IDENTITY=${IOS2_MAC_SIGNING_IDENTITY:--}
    if [ "$SIGNING_IDENTITY" != "none" ]; then
        echo "ios2: signing app with: $SIGNING_IDENTITY"
        codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH"
    fi

    echo "ios2: app: $APP_PATH"
}

package_dmg() {
    require_directory "$APP_PATH"
    mkdir -p "$OUTPUT_DIR"

    STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ios2-dmg.XXXXXX")
    trap 'rm -rf "$STAGE_DIR"' EXIT HUP INT TERM

    ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
    ln -s /Applications "$STAGE_DIR/Applications"

    rm -f -- "$DMG_PATH"
    hdiutil create \
        -volname "$DMG_VOLUME_NAME" \
        -srcfolder "$STAGE_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

    rm -rf "$STAGE_DIR"
    trap - EXIT HUP INT TERM
    echo "ios2: dmg: $DMG_PATH"
}

if [ "${1:-dmg}" = "help" ] || [ "${1:-dmg}" = "--help" ] || [ "${1:-dmg}" = "-h" ]; then
    print_usage
    exit 0
fi

case "${1:-dmg}" in
    clean)
        clean_build_artifacts
        ;;
    app)
        build_app
        ;;
    dmg)
        build_app
        package_dmg
        ;;
    *)
        print_usage >&2
        exit 2
        ;;
esac
