# CYZW Engine Shell

这是一个分层 iOS 游戏 Shell：SwiftUI 处理账号、工作区和插件；WebKit 承载可热更新业务页面；Cocos 负责单实例的原生战斗渲染。

## Directory structure

```text
ios/EngineHost/       L2 lifecycle protocol and shared data models
ios/Shell/            L1 SwiftUI account, workspace, plugin, and settings UI
ios/WebKitInstance/   L3-a isolated WKWebView runtime
ios/CocosInstance/    L3-b single-instance Cocos host and JSB bridge contract
ios/Plugins/          Plugin protocol, sandbox, and LoggerPlugin example
h5-ui/                Store, inventory, events, and game-settings pages
cocos-assets/         Ardot-derived Cocos texture and prefab manifests
shared/               Design tokens and bridge contract
ios-cocos/            Existing Cocos Creator 2.4.9 native runtime project
```

## Build

The Swift sources are deliberately target-agnostic. Add `ios/EngineHost`, `ios/Shell`, `ios/WebKitInstance`, `ios/CocosInstance`, and `ios/Plugins` to an iOS 17+ application target, then copy `shared/design-tokens.css` into the app bundle.

The bundled native Cocos runtime is built separately:

```sh
./ios-cocos/scripts/build_ios2.sh app-simulator
```

`CocosBridge` requires an Objective-C++ adapter that conforms to `CocosRuntimeAdapting` and forwards to that target's Cocos view, Director, and JSB runtime. The shipped Creator 2.4.9 integration exposes `CCEAGLView`; it is not a Metal `CCView` implementation.

## Run instances

Choose `WebKitInstance` for 2-4 independent workspace windows. Each one has its own `WKWebViewConfiguration` and non-persistent data store.

Choose `CocosNativeInstance` for 3D content. It is intentionally single-instance: its throwing initializer returns `EngineHostError.notMultiInstanceSupported` while another Cocos instance is alive. Call `close()` before creating another Cocos host.

## Plugin development

Implement `PluginProtocol`, then create a `PluginSandbox` with the target host ID and only the granted permissions. The sandbox delivers events and asks the plugin whether a resource injection is approved; it never gives the plugin a direct EngineHost reference. L1 remains responsible for calling `inject(resource:)`.

`LoggerPlugin` is the reference implementation. It subscribes to permitted events and writes a diagnostic line without requesting UI or resource permissions. Bridge event schemas and timing are documented in `shared/BRIDGE.md`.
