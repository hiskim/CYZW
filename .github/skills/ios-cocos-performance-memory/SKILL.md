---
name: ios-cocos-performance-memory
description: 排查和优化 IOS2 Cocos/WebKit 模式的首页空闲帧率、能耗、内存增长和退出/页面切换释放问题，适用于 CPU 占用高、15/60 FPS 切换异常、HSDK 日志过量或资源释放导致界面缺失/卡死的场景。
---

# IOS2 性能与内存优化

## 目标

降低 IOS2 首页和管理 UI 空闲时的 CPU/能耗，进入游戏后恢复目标帧率，并在 Cocos 与 WebKit 两种模式下控制页面切换、退出登录、重新登录带来的内存增长。优化必须保留游戏 UI、FairyGUI、Spine/DragonBones、HSDK 和 WebKit 多开链路的正确性。

## 核心约束

1. 先区分当前问题发生在首页管理 UI、Cocos 极速模式游戏内，还是 WebKit 多开 WKWebView 内。涉及运行模式切换、登录路由或登录后触摸异常时，同时读取 .github/skills/ios-cocos-runtime-modes/SKILL.md。
2. 首页未进入游戏时可以主动降帧或冻结非必要动画；进入游戏、恢复游戏、用户触摸唤醒和登录成功后必须恢复到配置目标帧率，不能长期停留在 15 FPS。
3. 不要把 Xcode 的 Metal API Validation 当作根因。它会影响调试环境，但如果关闭后 CPU/能耗不变，应继续排查主循环、定时器、日志、WebView、纹理和资源缓存。
4. 不要用全局 aggressive cleanup 粗暴调用 cc.assetManager.releaseUnusedAssets() 或释放 FairyGUI/Spine 正在依赖的资源。此前这类做法会导致按钮消失、游戏卡住。资源释放必须有明确所有权和场景边界。
5. 优先减少高频日志和序列化开销，尤其是 HSDK report_log_post、native bridge request、WebKit bridge message 这类可能在页面切换和埋点中持续触发的路径。HSDK 详细日志应由配置页开关控制，默认关闭。
6. 内存优化不能只看一次退出后的瞬时数值。iOS、JavaScriptCore/V8、WKWebView、Cocos texture cache 和 autorelease pool 都可能延迟回收；判断泄漏要看多轮切换后的峰值是否持续无界增长，以及对象/资源是否仍被引用。

## 优先排查位置

优先用这些锚点定位当前性能链路：

    rg -n "preferredFrameRate|setPreferredFrameRate|IOS2_LAUNCHER_IDLE_FRAME_RATE|IOS2_ACTIVE_DEFAULT_FRAME_RATE|freeze|resume|showFPS|HSDK|isOpenDebug|report_log_post|releaseUnusedAssets|removeFromParent|destroy|clearCache|WKWebView|webGameInstance|memory|residentMemory" ios-cocos

常见代码位置：

- ios-cocos/cocos-project/main.js：首页降帧、启动/登录后恢复帧率、HSDK 初始化与详细日志配置。
- ios-cocos/cocos-project/src/ios2-config-page.js：性能配置、FPS 显示、目标帧率、HSDK 详细日志开关。
- ios-cocos/cocos-project/src/ios2-manager.js：管理 UI 生命周期、登录后隐藏/恢复、Cocos 顶栏和弹窗清理。
- ios-cocos/cocos-project/src/ios2-account-services.js：Cocos/WebKit 登录入口、退出登录和重新登录流程。
- ios-cocos/cocos-project/src/ios2-web-boot.js：WebKit 游戏启动、桥接消息和 Web 端生命周期清理。
- ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm：原生性能偏好、帧率应用、内存读数、HSDK/native bridge 日志闸门。
- ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.mm：WKWebView 实例创建、关闭、消息 handler、导航停止和释放。

## 修改原则

1. 首页 CPU/能耗高时，先找持续触发源：schedule / setInterval、动画 tween、FPS 面板、管理页刷新、日志打印、bridge 心跳、WebKit 实例未关闭。能停就停，必须保留的降频。
2. 降帧逻辑要成对实现：进入首页或空闲时降到 idle 帧率；登录、恢复游戏、触摸唤醒、切后台返回和 WebKit/Cocos 游戏开始渲染时恢复到用户配置的目标帧率。
3. 对 HSDK 或第三方 SDK 只通过公开配置、wrapper、bridge 或本项目配置页控制，不直接修改 minified SDK 源码。
4. 处理页面切换内存增长时，先修引用生命周期：事件监听、touch handler、cc.tween、定时器、popup layer、FGUI object、WKScriptMessageHandler、block capture 和单例数组。不要先用清缓存掩盖仍被引用的对象。
5. Cocos 资源释放要按所有权处理。管理 UI 自己创建的临时节点、弹窗、列表、预览图可以在关闭时 removeFromParent / destroy；游戏 bundle、公用 atlas、Spine、FGUI 包和登录后仍可能复用的资源不要在页面切换中强制释放。
6. WebKit 退出或重登时，应停止加载、移除 script message handlers、断开 delegate、从父视图移除 WKWebView，并清掉本项目持有的实例引用；不要依赖 WKWebView 立即把进程内存降回初始值。
7. 对“两个页面资源相同但内存增长”的问题，重点检查重复创建的 UI 节点、重复注册监听、重复加载但未复用的图集/纹理、闭包引用旧页面、日志 JSON 序列化和延迟释放，而不是默认认为同资源不会增长。
8. 如果优化引入按钮消失、白屏、触摸无响应或游戏卡住，优先回退最近的资源释放/节点销毁策略，改成更窄的页面级清理。

## 验证

从仓库根目录执行相关静态检查，按实际改动文件选择：

    node --check ios-cocos/cocos-project/main.js
    node --check ios-cocos/cocos-project/src/ios2-config-page.js
    node --check ios-cocos/cocos-project/src/ios2-manager.js
    node --check ios-cocos/cocos-project/src/ios2-account-services.js
    node --check ios-cocos/cocos-project/src/ios2-web-boot.js
    git diff --check

使用 Xcode 构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -sdk iphonesimulator -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -quiet
```

手动真机验证至少覆盖：

- 首页停留 30 秒，CPU/能耗相对优化前下降，且配置页按钮仍完整可点。
- WebKit 模式登录后帧率从 idle 值恢复到目标帧率，退出后再次登录不持续叠加 WKWebView 或 bridge listener。
- Cocos 模式两个游戏内页面连续切换多轮，内存峰值可以回落或趋稳，按钮、Spine/FGUI 资源不消失，游戏不卡住。
- HSDK 详细日志关闭时高频埋点日志减少；开启时能恢复足够排查的信息。
- 退出登录、重登、切后台返回后，管理 UI 和游戏触摸都能正常响应。

最终回复用户时说明是否做了真机构建/运行验证；如果没有，只说明已完成静态校验和需要用户在 Xcode Instruments/Energy Report 中复测的指标。
