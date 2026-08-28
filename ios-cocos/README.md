# ios2: native Cocos 2.4.9 runtime

This directory is a separate native iOS path. It does not use the old `ios/`
WebView app, Python, Electron, or `app.asar` patching.

The runtime is Cocos Creator 2.4.9 JSB. The original app already contains the
matching built JavaScript and native-format resources, so the preparation
script imports those files without converting `.pvr` assets to `.bin` or PNG.

## Prepare the project

Run from the repository root:

```sh
./ios2/scripts/prepare_ios2.sh
```

The generated project uses the installed engine at
`/Applications/Cocos/Creator/2.4.9/CocosCreator.app/Contents/Resources/cocos2d-x`.
Override it with `IOS2_COCOS_ROOT`. `IOS2_SOURCE_APP` is only needed to restore
bootstrap files that are missing from the checkout.

Preparation copies only the small `assets/internal` and `assets/main`
bootstrap bundles into `cocos-project/assets`. The remaining game resources
are downloaded from the CDN at runtime; the full source-app assets directory
is never linked or copied into the project.

## Open and build

After preparation, open:

```text
ios2/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj
```

The first build compiles the Cocos static library from the installed 2.4.9
source. Use the `IOS2-mobile` target and set the signing team in Xcode for a
device build. The template's simulator target is useful for checking startup,
but PVR/GLES behavior should be verified on a real iOS device.

The generated app starts `main.js`, loads the original JSB adapter and remote
bundle manifest, and leaves CDN asset downloading to Cocos' native asset
manager. `.pvr` textures are therefore decoded by the Cocos native renderer;
they are not converted to H5 `.bin` files. The `.bin` account flow uses an
iOS document picker and `NSURLSession`, then feeds the server response back to
the game's native JSB `XMLHttpRequest` without a WebView.

## First run on a real iPhone

1. Prepare the project from the repository root:

   ```sh
   ./ios2/scripts/prepare_ios2.sh
   ```

2. Open `ios2/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj`
   in Xcode.

3. Select the `IOS2-mobile` scheme, select your connected iPhone, and set your
   Apple Developer Team under Signing & Capabilities. The bundle identifier is
   `com.xyzw.ios2`; change it if that identifier is already in use.

4. Build and run. On first launch, choose the account `.bin` file in the iOS
   document picker. The app posts it to `/login/authuser` with
   `O4e-Encoding: lx`, then the game continues through the normal login flow.

The downloaded manifest and remote bundles are cached by Cocos under the app's
local storage.

## Selectable game runtime

The account manager can start either of two isolated game backends:

- `Cocos 极速` keeps the existing Creator 2.4.9 JSB/native renderer. It is the
   default, remains single-instance, and does not load imported JS scripts.
- `WebKit 多开` creates one isolated `WKWebView` for every selected account.
   Each instance has its own non-persistent data store, JavaScript realm,
   login response, WebGL canvas, imported JS script support, and multi-open UI.

Open `配置`, select `WebKit 多开`, then return to the account page and press
`多开`. Select 2 to 4 bin files and confirm. Two instances use a vertical split,
three use a 2+1 grid, and four use a 2x2 grid. All instances use the app's
internal Web entry and the same CDN/cache namespace as the native runtime; no
external Web entry URL is configured by the user.

The normal `登录` button also works in WebKit mode. It authenticates that bin
file and opens one full-screen WebKit game instance.

The WebKit instances receive the live native manifest before startup, so both
backends use the same current bundle versions and cache keys. The bundled
Creator 2.4.9 Web engine parses standard PVR/PVRTC textures, while the runtime
also detects the CDN's ASTC payloads stored with a `.pvr` suffix and uploads
them through `WEBGL_compressed_texture_astc`. Texture candidates remain
restricted to `.pvr`; startup fails if neither PVRTC nor ASTC is available.
No PNG or WebP fallback is used:

```js
IOS2PVR.load(gl, textureURL).then(function (result) {
      // result.texture is the compressed WebGLTexture.
});
```

The page reports both PVRTC and ASTC WebGL capabilities to the native log.
Current automatic upload supports PVR v3 PVRTC formats 2bpp/4bpp, RGB/RGBA,
and ASTC 2D block formats exposed by WebKit.
Validate the final CDN texture set on a physical iPhone because the simulator
does not provide representative compressed-texture GPU support.

## Account management UI

The first screen is an account manager implemented with the open-source
FairyGUI runtime for Cocos Creator 2.4. The runtime is pinned under
`cocos-project/src/vendor`, together with its MIT license.

The account flow is split by responsibility:

- `ios2-account-view.js` renders FairyGUI objects and emits user actions only.
- `ios2-account-presenter.js` coordinates view state and use cases.
- `ios2-account-services.js` owns native account storage and login bridge calls.
- `ios2-login.js` remains the transport adapter for the game's auth request.

This boundary allows a FairyGUI Editor package to replace the programmatic view
without changing account persistence or authentication behavior.

The in-app `JS 脚本` page is available only in `WebKit 多开` mode and has a
`资源 JS 配置` sub-menu. It uses the bundled
`src/settings.*.js` by default. Importing a Creator settings script stores it
as `Documents/ios2/settings.js`; the next app launch evaluates that file before
the Cocos engine and uses it in place of the bundled settings. `恢复 App 配置`
deletes the override and returns to the bundled file. A malformed override is
ignored automatically and the bundled settings remain the fallback.

## Build from the command line

```sh
./ios2/scripts/build_ios2.sh engine
./ios2/scripts/build_ios2.sh app-simulator
./ios2/scripts/build_ios2.sh app-device
./ios2/scripts/build_ios2.sh clean
```

`clean` removes this checkout's simulator/device DerivedData and the generated
`cocos-project/ios-libs/libcocos2d iOS.a`. It leaves source files, generated
Xcode projects, assets, and IPA output untouched.

`app-device` builds an arm64 device app and automatically creates the
unsigned IPA at `ios2/build/IOS2-mobile-device.ipa`. Copy that IPA to the
iPhone and install it with TrollStore. A normally signed App Store/device
installation still requires selecting a signing team in Xcode.

`app-simulator` automatically opens the Simulator, boots the selected device,
installs the built app, and launches it with `simctl`. The default device is
`iPhone 17 Pro`; pass a device name as the second argument or set an explicit
name/UDID:

```sh
./ios2/scripts/build_ios2.sh app-simulator "iPhone 17 Pro Max"
IOS2_SIMULATOR_UDID=840CF757-A12D-40AB-A64C-309C3B9EA65F ./ios2/scripts/build_ios2.sh app-simulator
```

The script writes derived data under a stable, clone-specific directory in
`$TMPDIR` (for example `/private/tmp/ios2-derived-<workspace-hash>`). This
keeps simulator and device intermediates isolated from other checkouts. Set
`IOS2_DERIVED_DATA` when a CI job needs an explicit location.

`app-simulator` is available for machines with an installed iOS Simulator
runtime. Simulator and device builds use separate derived-data directories and
the script passes the matching `SDKROOT`, so a device archive cannot be reused
for a simulator link. Override the simulator architecture with
`IOS2_SIMULATOR_ARCH=arm64` or `IOS2_SIMULATOR_ARCH=x86_64` when needed.

If Xcode reports `No available simulator runtimes for platform iphonesimulator`
while compiling `Images.xcassets`, install an iOS Simulator runtime from
Xcode Settings > Components. This is an Xcode installation issue, not a Cocos
or application link error.

## Debug WebKit in Xcode

Open `cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj`, select
the `IOS2-mobile` scheme and the Debug configuration, then choose an iPhone or
iOS Simulator and press Run. The `Prepare WebKit Runtime` build phase
automatically copies the matching Creator 2.4.9 browser engine and builds the
correct simulator/device Cocos archive, so switching Xcode destinations does
not reuse an archive from the other platform.

WebKit messages are forwarded to the Xcode console. Filter for these prefixes:

- `[ios2][web]` for JavaScript `console.log`, `console.warn`, and `console.error`.
- `[ios2] Web resource missing` for internal custom-scheme 404s.
- `[ios2] Web CDN request failed` for original CDN URLs and HTTP errors.
- `[ios2] Web game ... error` for JavaScript exceptions and rejected promises.

Debug builds on iOS 16.4 or newer mark each game `WKWebView` as inspectable.
On the Mac, enable Safari > Settings > Advanced > Show features for web
developers, then use Safari > Develop to inspect the running simulator/device
canvas, network requests, JavaScript console, and loaded resources.

The CDN publishes executable bundles as XXTEA-encrypted `.jsc` files. WebKit
mode intercepts Creator's `.js` bundle requests, downloads the matching `.jsc`,
decrypts it with the H5 loader key, and evaluates the resulting text JavaScript.
This is distinct from V8 bytecode and is compatible with JavaScriptCore. The
engine and bootstrap structure were verified against the existing H5 renderer
under `autoupdate/APP/out/renderer`.

The project carries the verified Creator 2.4.9 web-mobile engine at
`cocos-project/src/ios2-web-cocos2d.js`, and preparation scripts use that
project-local copy by default. To refresh it, run the preparation script once
with `IOS2_WEB_ENGINE=/path/to/cocos2d-js-min.js`; subsequent builds do not
depend on the external build directory.
