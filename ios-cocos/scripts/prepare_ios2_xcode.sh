#!/bin/sh
set -eu

if [ -z "${SRCROOT:-}" ]; then
    echo "error: SRCROOT is required" >&2
    exit 1
fi

PROJECT_ROOT=$(CDPATH= cd -- "$SRCROOT/../../.." && pwd)
IOS2_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT/.." && pwd)
COCOS_RESOURCES_ROOT=${IOS2_COCOS_RESOURCES_ROOT:-/Applications/Cocos/Creator/2.4.9/CocosCreator.app/Contents/Resources}
WEB_ENGINE_TARGET="$PROJECT_ROOT/src/ios2-web-cocos2d.js"
WEB_ENGINE_SOURCE=${IOS2_WEB_ENGINE:-}
ENGINE_PROJECT="$PROJECT_ROOT/frameworks/cocos2d-x-local/build/cocos2d_libs.xcodeproj"
ENGINE_OUTPUT="$PROJECT_ROOT/ios-libs/libcocos2d iOS.a"
BUILD_ROOT="$IOS2_ROOT/build/xcode-engine-${PLATFORM_NAME:-iphoneos}"
CONFIGURATION=${CONFIGURATION:-Debug}

if [ -n "$WEB_ENGINE_SOURCE" ] && { [ ! -f "$WEB_ENGINE_TARGET" ] || ! cmp -s "$WEB_ENGINE_SOURCE" "$WEB_ENGINE_TARGET"; }; then
    if [ ! -f "$WEB_ENGINE_SOURCE" ]; then
        echo "error: compatible Cocos Web engine not found: $WEB_ENGINE_SOURCE" >&2
        exit 1
    fi
    cp "$WEB_ENGINE_SOURCE" "$WEB_ENGINE_TARGET"
fi
if [ ! -f "$WEB_ENGINE_TARGET" ]; then
    echo "error: project-local Cocos Web engine not found: $WEB_ENGINE_TARGET" >&2
    echo "error: set IOS2_WEB_ENGINE=/path/to/cocos2d-js-min.js once to import a replacement." >&2
    exit 1
fi

# The supplied 2.4.9 Web build assumes the WeChat global exists on a WebGL
# startup failure. WKWebView does not provide it, so keep this guard after
# copying the engine on every Xcode build.
perl -0pi -e 's/(console\.error\("This device does not support webgl"\),\s*)wx\)\)/$1typeof wx !== "undefined" \&\& wx))/g' "$WEB_ENGINE_TARGET"

if [ ! -f "$ENGINE_PROJECT/project.pbxproj" ]; then
    echo "error: Cocos engine project not found: $ENGINE_PROJECT" >&2
    exit 1
fi

case "${PLATFORM_NAME:-iphoneos}" in
    iphonesimulator)
        SDK=iphonesimulator
        PRODUCT_DIR="$BUILD_ROOT/Build/Products/${CONFIGURATION}-iphonesimulator"
        ;;
    iphoneos)
        SDK=iphoneos
        PRODUCT_DIR="$BUILD_ROOT/Build/Products/${CONFIGURATION}-iphoneos"
        ;;
    *)
        echo "error: unsupported Xcode platform: ${PLATFORM_NAME:-<empty>}" >&2
        exit 1
        ;;
esac

ENGINE_ARCH=${CURRENT_ARCH:-}
case "$ENGINE_ARCH" in
    ""|undefined_arch)
        ENGINE_ARCH=$(printf '%s' "${ARCHS:-arm64}" | awk '{ print $1 }')
        ;;
esac
case "$ENGINE_ARCH" in
    ""|undefined_arch)
        ENGINE_ARCH=arm64
        ;;
esac

xcodebuild \
    -project "$ENGINE_PROJECT" \
    -scheme 'libcocos2d iOS' \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    -derivedDataPath "$BUILD_ROOT" \
    SDKROOT="$SDK" \
    ARCHS="$ENGINE_ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO

LIBRARY="$PRODUCT_DIR/libcocos2d iOS.a"
if [ ! -f "$LIBRARY" ]; then
    echo "error: Cocos engine library not found: $LIBRARY" >&2
    exit 1
fi

mkdir -p "$PROJECT_ROOT/ios-libs"
if [ "$SDK" = iphonesimulator ]; then
    NORMALIZE_TOOL="$BUILD_ROOT/normalize_archive_macho"
    HOST_SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
    /usr/bin/env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="${HOME:-/tmp}" \
        TMPDIR="${TMPDIR:-/tmp}" /usr/bin/xcrun --sdk macosx clang \
        -target "$(uname -m)-apple-macos12" -std=c11 -O2 -isysroot "$HOST_SDK" \
        "$IOS2_ROOT/scripts/normalize_archive_macho.c" -o "$NORMALIZE_TOOL"
    NORMALIZED_LIBRARY="$LIBRARY.normalized"
    /usr/bin/env -u DYLD_ROOT_PATH "$NORMALIZE_TOOL" "$LIBRARY" "$NORMALIZED_LIBRARY"
    mv "$NORMALIZED_LIBRARY" "$ENGINE_OUTPUT"
    ranlib "$ENGINE_OUTPUT" >/dev/null 2>&1
else
    cp "$LIBRARY" "$ENGINE_OUTPUT"
fi
