#!/bin/sh
set -eu

# The Cocos 2.4.9 third-party archives contain a few object files with the
# legacy LC_VERSION_MIN_IPHONEOS command. Xcode's simulator linker rejects
# those members when the app target links the dependent Cocos target.
case "${PLATFORM_NAME:-${EFFECTIVE_PLATFORM_NAME:-}}:${BUILT_PRODUCTS_DIR:-}" in
    iphonesimulator:*|*-iphonesimulator)
        ;;
    *)
    exit 0
        ;;
esac

ENGINE_ARCHIVE="${BUILT_PRODUCTS_DIR:-}/libcocos2d iOS.a"
if [ ! -f "$ENGINE_ARCHIVE" ]; then
    exit 0
fi

echo "ios2: normalizing simulator Cocos archive: $ENGINE_ARCHIVE"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOL_DIR="${TARGET_TEMP_DIR:-${DERIVED_FILE_DIR:-/tmp}}/ios2-tools"
mkdir -p "$TOOL_DIR"
STRIP_TOOL="$TOOL_DIR/strip_legacy_macho"
cc -std=c11 -O2 "$SCRIPT_DIR/strip_legacy_macho.c" -o "$STRIP_TOOL"

ARCHIVE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ios2-normalize-archive.XXXXXX")
cleanup() {
    rm -rf "$ARCHIVE_TMP"
}
trap cleanup EXIT HUP INT TERM

(cd "$ARCHIVE_TMP" && ar -x "$ENGINE_ARCHIVE")
set -- "$ARCHIVE_TMP"/*.o
if [ ! -e "$1" ]; then
    exit 0
fi

for OBJECT in "$@"; do
    "$STRIP_TOOL" "$OBJECT" "$OBJECT.normalized"
    mv "$OBJECT.normalized" "$OBJECT"
done

libtool -static -o "$ARCHIVE_TMP/libcocos2d-ios-normalized.a" "$@"
mv "$ARCHIVE_TMP/libcocos2d-ios-normalized.a" "$ENGINE_ARCHIVE"
