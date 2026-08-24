#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS2_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_ROOT="$IOS2_ROOT/cocos-project"

SOURCE_APP=${IOS2_SOURCE_APP:-/Volumes/WD/tk-mobile.app}
COCOS_ROOT=${IOS2_COCOS_ROOT:-/Applications/Cocos/Creator/2.4.9/CocosCreator.app/Contents/Resources/cocos2d-x}
COCOS_RESOURCES_ROOT=${IOS2_COCOS_RESOURCES_ROOT:-$(dirname "$COCOS_ROOT")}
TEMPLATE_ROOT="$COCOS_ROOT/templates/js-template-default"
IOS_PROJECT_DIR="$PROJECT_ROOT/frameworks/runtime-src/proj.ios_mac"
IOS_PROJECT="$IOS_PROJECT_DIR/IOS2.xcodeproj"
IOS_COMPAT_LIBS="$PROJECT_ROOT/ios-libs"
LOCAL_ENGINE_ROOT="$PROJECT_ROOT/frameworks/cocos2d-x-local"
LOCAL_ENGINE_PROJECT="$LOCAL_ENGINE_ROOT/build/cocos2d_libs.xcodeproj"

if [ ! -d "$TEMPLATE_ROOT" ]; then
    echo "ios2: Cocos 2.4.9 template not found: $TEMPLATE_ROOT" >&2
    exit 1
fi

WEB_ENGINE_SOURCE="$COCOS_RESOURCES_ROOT/engine/bin/cocos2d-js-for-preview.js"
WEB_ENGINE_TARGET="$PROJECT_ROOT/src/ios2-web-cocos2d.js"
if [ ! -f "$WEB_ENGINE_SOURCE" ]; then
    echo "ios2: Cocos 2.4.9 Web engine not found: $WEB_ENGINE_SOURCE" >&2
    exit 1
fi

require_source_app() {
    if [ ! -d "$SOURCE_APP" ]; then
        echo "ios2: source app is required to restore missing bootstrap files: $SOURCE_APP" >&2
        exit 1
    fi
}

# Cocos 2.4.9 ships an old libwebp archive whose members are not aligned for
# current Xcode linkers. Repack the available simulator/device slices locally
# without changing the installed Cocos distribution.
WEBP_SOURCE="$COCOS_ROOT/external/ios/libs/libwebp.a"
if [ -f "$WEBP_SOURCE" ] && command -v lipo >/dev/null 2>&1 && command -v libtool >/dev/null 2>&1; then
    mkdir -p "$IOS_COMPAT_LIBS"
    if [ ! -f "$IOS_COMPAT_LIBS/libwebp.a" ] || [ "$WEBP_SOURCE" -nt "$IOS_COMPAT_LIBS/libwebp.a" ]; then
        WEBP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ios2-webp.XXXXXX")
        WEBP_PARTS=""
        for WEBP_ARCH in arm64 x86_64; do
            WEBP_ARCH_DIR="$WEBP_TMP/$WEBP_ARCH"
            mkdir -p "$WEBP_ARCH_DIR"
            if lipo -thin "$WEBP_ARCH" "$WEBP_SOURCE" -output "$WEBP_ARCH_DIR/libwebp-thin.a" 2>/dev/null; then
                (cd "$WEBP_ARCH_DIR" && ar -x libwebp-thin.a && libtool -static -o libwebp.a ./*.o)
                WEBP_PARTS="$WEBP_PARTS $WEBP_ARCH_DIR/libwebp.a"
            fi
        done
        if [ -n "$WEBP_PARTS" ]; then
            lipo -create $WEBP_PARTS -output "$IOS_COMPAT_LIBS/libwebp.a"
        fi
        rm -rf "$WEBP_TMP"
    fi
fi

mkdir -p "$PROJECT_ROOT"
if [ ! -f "$PROJECT_ROOT/frameworks/runtime-src/Classes/AppDelegate.cpp" ]; then
    cp -R "$TEMPLATE_ROOT/." "$PROJECT_ROOT/"
fi

# Keep the large engine outside the repository while preserving the path that
# the generated Cocos Xcode project expects.
mkdir -p "$PROJECT_ROOT/frameworks"
if [ -e "$PROJECT_ROOT/frameworks/cocos2d-x" ] && [ ! -L "$PROJECT_ROOT/frameworks/cocos2d-x" ]; then
    mv "$PROJECT_ROOT/frameworks/cocos2d-x" "$PROJECT_ROOT/frameworks/cocos2d-x.template"
fi
ln -sfn "$COCOS_ROOT" "$PROJECT_ROOT/frameworks/cocos2d-x"

# The stock engine project hard-codes SDKROOT=iphoneos in its iOS target.
# Keep a small local project wrapper so simulator builds can inherit the
# parent SDK, while all engine sources remain linked to the installed Cocos.
if [ ! -f "$LOCAL_ENGINE_PROJECT/project.pbxproj" ]; then
    mkdir -p "$LOCAL_ENGINE_ROOT/build"
    cp -R "$COCOS_ROOT/build/." "$LOCAL_ENGINE_ROOT/build/"
    perl -0pi -e 's/SDKROOT = iphoneos;/SDKROOT = "\$(SDKROOT)";/g' "$LOCAL_ENGINE_PROJECT/project.pbxproj"
fi
# Cocos 2.4.9's V8 regexp JIT can execute from a non-executable page on iOS
# 16 devices and crash with SIGBUS. Force the interpreter for every generated
# iOS engine configuration while keeping the installed Cocos distribution intact.
if [ -f "$LOCAL_ENGINE_PROJECT/project.pbxproj" ] && ! grep -q 'CC_IOS_FORCE_DISABLE_JIT=1' "$LOCAL_ENGINE_PROJECT/project.pbxproj"; then
    perl -0pi -e 's/("V8_TYPED_ARRAY_MAX_SIZE_IN_HEAP=64",\n)/$1\t\t\t\t\t"CC_IOS_FORCE_DISABLE_JIT=1",\n/g' "$LOCAL_ENGINE_PROJECT/project.pbxproj"
fi
for ENGINE_DIR in cocos extensions external; do
    ln -sfn "$COCOS_ROOT/$ENGINE_DIR" "$LOCAL_ENGINE_ROOT/$ENGINE_DIR"
done

# The repository carries the customized JS runtime. Only import the original
# app's files when bootstrapping a previously empty project; never overwrite
# tracked ios2 changes as a side effect of a build.
if [ ! -f "$PROJECT_ROOT/main.js" ]; then
    require_source_app
    cp "$SOURCE_APP/main.js" "$PROJECT_ROOT/main.js"
fi
if [ ! -f "$PROJECT_ROOT/project.json" ]; then
    require_source_app
    cp "$SOURCE_APP/project.json" "$PROJECT_ROOT/project.json"
fi
if [ ! -d "$PROJECT_ROOT/jsb-adapter" ]; then
    require_source_app
    mkdir -p "$PROJECT_ROOT/jsb-adapter"
    cp -R "$SOURCE_APP/jsb-adapter/." "$PROJECT_ROOT/jsb-adapter/"
fi
if [ ! -d "$PROJECT_ROOT/src" ]; then
    require_source_app
    mkdir -p "$PROJECT_ROOT/src"
    cp -R "$SOURCE_APP/src/." "$PROJECT_ROOT/src/"
fi

if [ ! -f "$WEB_ENGINE_TARGET" ] || [ "$WEB_ENGINE_SOURCE" -nt "$WEB_ENGINE_TARGET" ]; then
    cp "$WEB_ENGINE_SOURCE" "$WEB_ENGINE_TARGET"
fi

# Install the native login bridge into the copied startup script. Keeping this
# injection here makes prepare_ios2.sh repeatable without modifying the source
# app's main.js.
if ! grep -q 'src/ios2-login\.js' "$PROJECT_ROOT/main.js" 2>/dev/null; then
    perl -0pi -e 's/(require\("jsb-adapter\/game-defines\.js"\);)/$1\n        require("src\/ios2-login.js");/' "$PROJECT_ROOT/main.js"
fi

# Creator generates this registration unit in the native project. The stock
# template references it from both iOS targets, so import the matching 2.4.9
# version when preparing an otherwise empty native project.
if [ ! -f "$PROJECT_ROOT/frameworks/runtime-src/Classes/jsb_module_register.cpp" ]; then
    cp "$COCOS_ROOT/cocos/scripting/js-bindings/manual/jsb_module_register.cpp" \
        "$PROJECT_ROOT/frameworks/runtime-src/Classes/jsb_module_register.cpp"
fi

# Keep only the two bootstrap bundles needed before CDN downloads begin.
# Never link or copy the full source-app assets tree into the Xcode project.
if [ -L "$PROJECT_ROOT/assets" ] || [ ! -d "$PROJECT_ROOT/assets/internal" ] || [ ! -d "$PROJECT_ROOT/assets/main" ]; then
    require_source_app
    if [ -L "$PROJECT_ROOT/assets" ]; then
        rm -f "$PROJECT_ROOT/assets"
    elif [ -e "$PROJECT_ROOT/assets" ]; then
        rm -rf "$PROJECT_ROOT/assets"
    fi
    mkdir -p "$PROJECT_ROOT/assets/internal" "$PROJECT_ROOT/assets/main"
    cp -R "$SOURCE_APP/assets/internal/." "$PROJECT_ROOT/assets/internal/"
    cp -R "$SOURCE_APP/assets/main/." "$PROJECT_ROOT/assets/main/"
fi
# Remove any stale full-resource entries or filesystem metadata left by an
# earlier symlink/full-copy preparation. Only internal/main are valid here.
find "$PROJECT_ROOT/assets" -mindepth 1 -maxdepth 1 \
    ! -name internal ! -name main -exec rm -rf {} +
find "$PROJECT_ROOT/assets/internal" "$PROJECT_ROOT/assets/main" \
    -name .DS_Store -type f -delete

# The stock template names its product HelloJavascript. Rename only the
# generated project, leaving the installed Cocos template untouched.
if [ -f "$IOS_PROJECT_DIR/HelloJavascript.xcodeproj/project.pbxproj" ] && [ ! -e "$IOS_PROJECT" ]; then
    mv "$IOS_PROJECT_DIR/HelloJavascript.xcodeproj" "$IOS_PROJECT"
fi
if [ -f "$IOS_PROJECT/project.pbxproj" ]; then
    perl -0pi -e 's/HelloJavascript/IOS2/g; s/org\.cocos2dx\.hellojavascript/com\.xyzw\.ios2/g' "$IOS_PROJECT/project.pbxproj"
    perl -0pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = 10\.0;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g' "$IOS_PROJECT/project.pbxproj"
    # Let Xcode manage signing for device builds. The team is account-specific
    # and must be selected in Signing & Capabilities (or supplied by Xcode's
    # user settings), so do not commit an empty or guessed team identifier.
    perl -0pi -e 's/^\s+CODE_SIGN_IDENTITY = "iPhone Developer";\r?\n//mg; s/^\s+DEVELOPMENT_TEAM = "";\r?\n//mg; s/^\s+CODE_SIGN_STYLE = Automatic;\r?\n//mg; s/(ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n)/$1\t\t\t\tCODE_SIGN_STYLE = Automatic;\n/g; s/ALWAYS_SEARCH_USER_PATHS = YES;/ALWAYS_SEARCH_USER_PATHS = NO;/g' "$IOS_PROJECT/project.pbxproj"
    if ! grep -q 'ENABLE_DEBUG_DYLIB = NO;' "$IOS_PROJECT/project.pbxproj"; then
        perl -0pi -e 's/(ENABLE_BITCODE = NO;\n)/$1\t\t\t\tENABLE_DEBUG_DYLIB = NO;\n/g' "$IOS_PROJECT/project.pbxproj"
    fi
    if ! grep -q 'IOS2_WEBKIT_DEBUG=1' "$IOS_PROJECT/project.pbxproj"; then
        perl -0pi -e 's/(A92277011517C097001B78AA \/\* Debug \*\/ = \{[\s\S]*?GCC_PREPROCESSOR_DEFINITIONS = \(\n\s+CC_TARGET_OS_IPHONE,\n)/$1\t\t\t\t\t"IOS2_WEBKIT_DEBUG=1",\n/' "$IOS_PROJECT/project.pbxproj"
    fi
    # With ALWAYS_SEARCH_USER_PATHS disabled, old Cocos angle-bracket includes
    # need to be in HEADER_SEARCH_PATHS (USER_HEADER_SEARCH_PATHS becomes -iquote).
    perl -0pi -e 's/(ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;[\s\S]*?HEADER_SEARCH_PATHS = )"";/$1"\$(inherited) \$(SRCROOT)\/..\/..\/cocos2d-x \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/base \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/physics \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/math\/kazmath \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/2d \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/gui \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/network \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/audio\/include \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/editor-support \$(SRCROOT)\/..\/..\/cocos2d-x\/extensions \$(SRCROOT)\/..\/..\/cocos2d-x\/external \$(SRCROOT)\/..\/..\/cocos2d-x\/external\/sources \$(SRCROOT)\/..\/..\/cocos2d-x\/external\/chipmunk\/include\/chipmunk \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/scripting\/js-bindings\/auto \$(SRCROOT)\/..\/..\/cocos2d-x\/cocos\/scripting\/js-bindings\/manual \$(SRCROOT)\/..\/..\/cocos2d-x\/external\/mac\/include\/v8";/g' "$IOS_PROJECT/project.pbxproj"
    perl -0pi -e 's|path = "../../cocos2d-x/build/cocos2d_libs\.xcodeproj";|path = "../../cocos2d-x-local/build/cocos2d_libs.xcodeproj";|g' "$IOS_PROJECT/project.pbxproj"
    # This generated target is the iOS app target. Keep its SDK explicit so
    # Xcode exposes connected iPhone destinations for the scheme.
    perl -0pi -e 's/SDKROOT = "\$\(SDKROOT\)";/SDKROOT = iphoneos;/g' "$IOS_PROJECT/project.pbxproj"
    perl -0pi -e 's|LIBRARY_SEARCH_PATHS = "\$\(SRCROOT\)/\.\./\.\./cocos2d-x/external/ios/libs";|LIBRARY_SEARCH_PATHS = (\n\t\t\t\t\t"\$(SRCROOT)/../../../ios-libs",\n\t\t\t\t\t"\$(SRCROOT)/../../cocos2d-x/external/ios/libs",\n\t\t\t\t);|g' "$IOS_PROJECT/project.pbxproj"
    if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.xyzw.ios2;' "$IOS_PROJECT/project.pbxproj"; then
        perl -0pi -e 's/(INFOPLIST_FILE = ios\/Info\.plist;\n\s+IPHONEOS_DEPLOYMENT_TARGET = 15\.0;)/$1\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.xyzw.ios2;/g' "$IOS_PROJECT/project.pbxproj"
    fi

    # AppController.mm uses UIDocumentPicker's UTType API. Add the framework
    # to the generated iOS target once, so repeated preparation is idempotent.
    if ! grep -q 'UniformTypeIdentifiers.framework in Frameworks' "$IOS_PROJECT/project.pbxproj"; then
        perl -0pi -e 's|(A922754C1517C094001B78AA /\* UIKit\.framework in Frameworks \*/ = \{isa = PBXBuildFile; fileRef = A922754B1517C094001B78AA /\* UIKit\.framework \*/; \};)|$1\n\t\t6B75B0D12345678900000001 /* UniformTypeIdentifiers.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 6B75B0D12345678900000002 /* UniformTypeIdentifiers.framework */; };|' "$IOS_PROJECT/project.pbxproj"
        perl -0pi -e 's|(A922754B1517C094001B78AA /\* UIKit\.framework \*/ = \{isa = PBXFileReference; lastKnownFileType = wrapper\.framework; name = UIKit\.framework; path = System/Library/Frameworks/UIKit\.framework; sourceTree = SDKROOT; \};)|$1\n\t\t6B75B0D12345678900000002 /* UniformTypeIdentifiers.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = UniformTypeIdentifiers.framework; path = System/Library/Frameworks/UniformTypeIdentifiers.framework; sourceTree = SDKROOT; };|' "$IOS_PROJECT/project.pbxproj"
        perl -0pi -e 's|(A922754C1517C094001B78AA /\* UIKit\.framework in Frameworks \*/,)|$1\n\t\t\t\t6B75B0D12345678900000001 /* UniformTypeIdentifiers.framework in Frameworks */,|' "$IOS_PROJECT/project.pbxproj"
        perl -0pi -e 's|(A922754B1517C094001B78AA /\* UIKit\.framework \*/,)|$1\n\t\t\t\t6B75B0D12345678900000002 /* UniformTypeIdentifiers.framework */,|' "$IOS_PROJECT/project.pbxproj"
    fi

    # Cocos' iOS static library uses WebP symbols. Keep the dependency on the
    # iOS library search path for both Debug and Release app builds.
    if ! grep -q '"-lwebp"' "$IOS_PROJECT/project.pbxproj"; then
        perl -0pi -e 's/(\t\t\t\t"-ObjC",\n)/$1\t\t\t\t"-lwebp",\n/g' "$IOS_PROJECT/project.pbxproj"
    fi

    # iOS downloads game bundles from the CDN. Embed only the checkout's
    # assets folder, which is intentionally limited to internal/main bootstrap
    # data. This also makes direct Xcode builds equivalent to build_ios2.sh.
    perl -0pi -e 's/^\s+286B0E98240761C500095E1A \/\* assets in Resources \*\/ = .*\r?\n//mg; s/^\s+288D4373225B43BE0075FBAB \/\* assets in Resources \*\/ = .*\r?\n//mg; s/^\s+286B0E98240761C500095E1A \/\* assets in Resources \*\/,\r?\n//mg; s/^\s+288D4373225B43BE0075FBAB \/\* assets in Resources \*\/,\r?\n//mg' "$IOS_PROJECT/project.pbxproj"
    if ! grep -q '288D4373225B43BE0075FBAC /\* assets in Resources \*/' "$IOS_PROJECT/project.pbxproj"; then
        perl -0pi -e 's|(1AFFCD871F7A5DCF00628F2C \/\* LaunchScreenBackground\.png in Resources \*\/ = .*\n)|$1\t\t288D4373225B43BE0075FBAC \/\* assets in Resources \*\/ = {isa = PBXBuildFile; fileRef = 288D4372225B43BE0075FBAB \/\* assets \*\/; };\n|' "$IOS_PROJECT/project.pbxproj"
        perl -0pi -e 's|(\t+1AD7E0A918C9DBE3004817A6 \/\* main\.js in Resources \*\/,\n)|$1\t\t\t\t288D4373225B43BE0075FBAC \/\* assets in Resources \*\/,\n|; s|(\t+1AD7E0A818C9DB93004817A6 \/\* main\.js in Resources \*\/,\n)|$1\t\t\t\t288D4373225B43BE0075FBAC \/\* assets in Resources \*\/,\n|' "$IOS_PROJECT/project.pbxproj"
    fi

fi

if [ -f "$IOS_PROJECT_DIR/ios/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.xyzw.ios2' "$IOS_PROJECT_DIR/ios/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 咸鱼之王 Native' "$IOS_PROJECT_DIR/ios/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Set :MinimumOSVersion 15.0' "$IOS_PROJECT_DIR/ios/Info.plist" 2>/dev/null || true
fi

echo "ios2 prepared:"
echo "  project: $IOS_PROJECT"
echo "  engine:  $COCOS_ROOT"
echo "  source:  ${SOURCE_APP} (used only to restore missing bootstrap files)"
echo "  assets:  copied internal/main bootstrap bundles"
