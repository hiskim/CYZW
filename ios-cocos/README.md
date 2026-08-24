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

The in-app `JS 脚本` page has a `资源 JS 配置` sub-menu. It uses the bundled
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
