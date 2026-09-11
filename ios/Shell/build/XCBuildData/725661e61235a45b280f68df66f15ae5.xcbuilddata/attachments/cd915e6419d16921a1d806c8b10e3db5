#!/bin/sh
set -eu
RUNTIME="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/WebRuntime"
mkdir -p "$RUNTIME"
ditto "${SRCROOT}/../../ios-cocos/cocos-project/src" "$RUNTIME/src"
ditto "${SRCROOT}/../../ios-cocos/cocos-project/assets" "$RUNTIME/assets"
mkdir -p "$RUNTIME/jsb-adapter"
ditto "${SRCROOT}/../../ios-cocos/cocos-project/jsb-adapter/game-defines.js" "$RUNTIME/jsb-adapter/game-defines.js"

