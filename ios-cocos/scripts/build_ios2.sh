#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS2_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_ROOT="$IOS2_ROOT/cocos-project"
ENGINE_PROJECT="$PROJECT_ROOT/frameworks/cocos2d-x-local/build/cocos2d_libs.xcodeproj"
APP_PROJECT="$PROJECT_ROOT/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj"
if [ -z "${IOS2_DERIVED_DATA:-}" ]; then
    # Keep clones of ios2 isolated from one another while retaining a stable
    # path for incremental builds. The override remains available for CI.
    IOS2_ROOT_HASH=$(printf '%s' "$IOS2_ROOT" | shasum -a 256 | awk '{print substr($1, 1, 12)}')
    DERIVED_DATA="${TMPDIR:-/private/tmp}/ios2-derived-$IOS2_ROOT_HASH"
else
    DERIVED_DATA=$IOS2_DERIVED_DATA
fi
DEVICE_DERIVED_DATA="$DERIVED_DATA/device"
SIMULATOR_DERIVED_DATA="$DERIVED_DATA/simulator"
SIMULATOR_ARCH=${IOS2_SIMULATOR_ARCH:-$(uname -m)}
BUNDLE_ID=com.xyzw.ios2
SIMULATOR_NAME=${IOS2_SIMULATOR_NAME:-${2:-iPhone 17 Pro}}
SIMULATOR_UDID=${IOS2_SIMULATOR_UDID:-}

resolve_simulator() {
    if [ -z "$SIMULATOR_UDID" ]; then
        SIMULATOR_UDID=$(xcrun simctl list devices available | awk -v name="$SIMULATOR_NAME" '
            {
                line = $0
                sub(/^[[:space:]]*/, "", line)
                prefix = name " ("
                if (index(line, prefix) == 1) {
                    value = substr(line, length(prefix) + 1)
                    sub(/\).*/, "", value)
                    print value
                    exit
                }
            }
        ')
    fi

    if [ -z "$SIMULATOR_UDID" ]; then
        echo "ios2: simulator not found: $SIMULATOR_NAME" >&2
        echo "ios2: available simulators:" >&2
        xcrun simctl list devices available | sed -n '/^-- iOS/,/^$/p' >&2
        exit 1
    fi

    echo "ios2: simulator: $SIMULATOR_NAME ($SIMULATOR_UDID)"
}

install_and_launch_simulator() {
    APP_PATH="$SIMULATOR_DERIVED_DATA/Build/Products/Debug-iphonesimulator/IOS2-mobile.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "ios2: simulator app not found: $APP_PATH" >&2
        exit 1
    fi

    echo "ios2: opening Simulator"
    open -a Simulator >/dev/null 2>&1 || true
    xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
    echo "ios2: waiting for simulator"
    if ! xcrun simctl bootstatus "$SIMULATOR_UDID" -b; then
        echo "ios2: simulator did not become ready: $SIMULATOR_UDID" >&2
        exit 1
    fi

    echo "ios2: installing $APP_PATH"
    xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
    echo "ios2: launching $BUNDLE_ID"
    xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID"
}

copy_local_bundle_bootstrap_files() {
    APP_PATH=$1

    for BUNDLE_NAME in internal main; do
        SOURCE_DIR="$PROJECT_ROOT/assets/$BUNDLE_NAME"
        TARGET_DIR="$APP_PATH/assets/$BUNDLE_NAME"

        # Cocos' internal bundle is required before any remote scene loads.
        # Copy its imports and native assets as well as its config and code.
        if [ -d "$SOURCE_DIR" ]; then
            mkdir -p "$TARGET_DIR"
            ditto "$SOURCE_DIR" "$TARGET_DIR"
        fi
    done
}

build_simulator_engine() {
    xcodebuild \
        -project "$ENGINE_PROJECT" \
        -scheme 'libcocos2d iOS' \
        -configuration Debug \
        -sdk iphonesimulator \
        -derivedDataPath "$SIMULATOR_DERIVED_DATA" \
        SDKROOT=iphonesimulator \
        ARCHS="$SIMULATOR_ARCH" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO

    ENGINE_LIBRARY="$SIMULATOR_DERIVED_DATA/Build/Products/Debug-iphonesimulator/libcocos2d iOS.a"
    if [ ! -f "$ENGINE_LIBRARY" ]; then
        echo "ios2: simulator engine library not found: $ENGINE_LIBRARY" >&2
        exit 1
    fi

    NORMALIZE_TOOL="$SIMULATOR_DERIVED_DATA/normalize_archive_macho"
    cc -std=c11 -O2 "$SCRIPT_DIR/normalize_archive_macho.c" -o "$NORMALIZE_TOOL"
    NORMALIZED_LIBRARY="$ENGINE_LIBRARY.normalized"
    "$NORMALIZE_TOOL" "$ENGINE_LIBRARY" "$NORMALIZED_LIBRARY"
    mv "$NORMALIZED_LIBRARY" "$ENGINE_LIBRARY"
    ranlib "$ENGINE_LIBRARY" >/dev/null 2>&1
    mkdir -p "$PROJECT_ROOT/ios-libs"
    cp "$ENGINE_LIBRARY" "$PROJECT_ROOT/ios-libs/libcocos2d iOS.a"
}

build_device_engine() {
    xcodebuild \
        -project "$ENGINE_PROJECT" \
        -scheme 'libcocos2d iOS' \
        -configuration Debug \
        -sdk iphoneos \
        -derivedDataPath "$DEVICE_DERIVED_DATA" \
        SDKROOT=iphoneos \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO

    ENGINE_LIBRARY="$DEVICE_DERIVED_DATA/Build/Products/Debug-iphoneos/libcocos2d iOS.a"
    if [ ! -f "$ENGINE_LIBRARY" ]; then
        echo "ios2: device engine library not found: $ENGINE_LIBRARY" >&2
        exit 1
    fi
    mkdir -p "$PROJECT_ROOT/ios-libs"
    cp "$ENGINE_LIBRARY" "$PROJECT_ROOT/ios-libs/libcocos2d iOS.a"
}

package_device_ipa() {
    APP_PATH="$DEVICE_DERIVED_DATA/Build/Products/Debug-iphoneos/IOS2-mobile.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "ios2: device app not found: $APP_PATH" >&2
        exit 1
    fi

    OUTPUT_DIR=${IOS2_OUTPUT_DIR:-$IOS2_ROOT/build}
    IPA_PATH=${IOS2_IPA_PATH:-$OUTPUT_DIR/IOS2-mobile-device.ipa}
    mkdir -p "$(dirname -- "$IPA_PATH")"
    IPA_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ios2-ipa.XXXXXX")
    trap 'rm -rf "$IPA_TMP"' EXIT HUP INT TERM
    mkdir -p "$IPA_TMP/Payload"
    cp -R "$APP_PATH" "$IPA_TMP/Payload/IOS2-mobile.app"
    /usr/bin/ditto -c -k --norsrc --keepParent "$IPA_TMP/Payload" "$IPA_PATH"
    if ! unzip -Z1 "$IPA_PATH" | awk '$0 == "Payload/IOS2-mobile.app/" { found = 1 } END { exit(found ? 0 : 1) }'; then
        echo "ios2: invalid IPA (Payload/IOS2-mobile.app is missing): $IPA_PATH" >&2
        exit 1
    fi
    rm -rf "$IPA_TMP"
    trap - EXIT HUP INT TERM
    echo "ios2: ipa: $IPA_PATH"
}

clean_build_artifacts() {
    # Refuse obviously unsafe overrides before the intentional recursive delete.
    case "$DERIVED_DATA" in
        ""|/)
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
    if [ -f "$PROJECT_ROOT/ios-libs/libcocos2d iOS.a" ]; then
        rm -f -- "$PROJECT_ROOT/ios-libs/libcocos2d iOS.a"
        echo "ios2: removed generated engine library"
    fi
}

case "${1:-app}" in
    clean)
        clean_build_artifacts
        exit 0
        ;;
esac

if [ ! -f "$APP_PROJECT/project.pbxproj" ] || [ ! -f "$ENGINE_PROJECT/project.pbxproj" ]; then
    echo "ios2: preparing generated Cocos/Xcode files"
    "$SCRIPT_DIR/prepare_ios2.sh"
fi

if [ ! -f "$APP_PROJECT/project.pbxproj" ]; then
    echo "ios2: app project not found after preparation: $APP_PROJECT" >&2
    exit 1
fi
if [ ! -f "$ENGINE_PROJECT/project.pbxproj" ]; then
    echo "ios2: engine project not found after preparation: $ENGINE_PROJECT" >&2
    exit 1
fi

case "${1:-app}" in
    engine)
        xcodebuild \
            -project "$ENGINE_PROJECT" \
            -scheme 'libcocos2d iOS' \
            -configuration Release \
            -sdk iphoneos \
            -derivedDataPath "$DEVICE_DERIVED_DATA" \
            SDKROOT=iphoneos \
            ARCHS=arm64 \
            CODE_SIGNING_ALLOWED=NO
        ;;
    app|app-simulator)
        resolve_simulator
        build_simulator_engine
        xcodebuild \
            -project "$APP_PROJECT" \
            -scheme IOS2-mobile \
            -configuration Debug \
            -sdk iphonesimulator \
            -derivedDataPath "$SIMULATOR_DERIVED_DATA" \
            -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
            SDKROOT=iphonesimulator \
            ARCHS="$SIMULATOR_ARCH" \
            ONLY_ACTIVE_ARCH=YES \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
        copy_local_bundle_bootstrap_files "$SIMULATOR_DERIVED_DATA/Build/Products/Debug-iphonesimulator/IOS2-mobile.app"
        install_and_launch_simulator
        ;;
    app-device)
        build_device_engine
        xcodebuild \
            -project "$APP_PROJECT" \
            -scheme IOS2-mobile \
            -configuration Debug \
            -sdk iphoneos \
            -derivedDataPath "$DEVICE_DERIVED_DATA" \
            -destination 'generic/platform=iOS' \
            SDKROOT=iphoneos \
            ARCHS=arm64 \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
        copy_local_bundle_bootstrap_files "$DEVICE_DERIVED_DATA/Build/Products/Debug-iphoneos/IOS2-mobile.app"
        package_device_ipa
        ;;
    *)
        echo "usage: $0 [clean|engine|app|app-simulator|app-device]" >&2
        exit 2
        ;;
esac
