---
name: ios2-webkit-multi-open-auth
description: 排查和维护 IOS2 WebKit 多开启动时 HSDK 重复登录、重复弹出 BIN 文件选择器或账号串线的问题；不适用于 Cocos 极速单开登录。
---

# WebKit 多开认证

## 目标

保证用户在 WebKit 多开页面启动前选择的每个 BIN 只认证一次。各 `WKWebView` 启动时的 HSDK 登录请求必须复用对应实例的预认证结果，不得再次打开 BIN 文件选择器，也不得把账号信息发给其他实例。

## 核心约束

1. 仅当 `IOS2Native.runtimeBackend` 严格等于 `webkit` 且存在多个游戏实例时，走 WebKit 多开认证分支；其他模式继续使用原有 Cocos 单开 `loginBinFile:` 流程。
2. 多开启动配置必须为每个实例携带独立的 `instanceID`、`accountID` 和 `authResponse`。`authResponse` 在 WebView 的 `/login/authuser` 假请求中直接返回，不能再次读取或选择 BIN。
3. HSDK 桥接请求必须使用消息中的 `__ios2Instance` 定位实例，并通过 `IOS2GameWebView accountIDForInstance:` 查询账号；禁止依赖一个会被并发实例覆盖的全局账号值。
4. 多开实例收到 `user_login_show_dialog`、`user-tokenlogin` 或 `user-multi-platform-login` 时，应发布该实例的用户信息并完成登录回调（例如 `IOS2FinishSDKLogin(0)`），不得调用 `selectLoginBin`。
5. `sdk-get-userId` / `user-getuserinfo` 同样按实例返回 `accountID`，否则登录虽然成功，游戏仍可能显示或使用错误账号。
6. 单账号 WebKit 登录仍可复用全局认证缓存；退出登录时要清理认证状态、HSDK 目标实例和全部 WebView，避免旧实例响应新请求。

## 优先排查位置

先用以下锚点定位调用链：

```sh
rg -n "loginForSDK|selectLoginBin|s_ios2HSDKTargetInstanceID|s_ios2SDKLoginPending|sdk-get-userId|accountIDForInstance|authResponse|runtimeBackend" \
  ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios \
  ios-cocos/cocos-project/src
```

重点文件：

- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`：HSDK 消息分发、`loginForSDK`、认证缓存、实例 ID 路由和运行模式兜底。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.mm`：创建多实例时注入 `authResponse` / `accountID`，以及 WebKit HSDK 消息转发。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.h`：实例账号查询和 HSDK 转发接口声明。
- `ios-cocos/cocos-project/src/ios2-account-services.js`、`ios2-manager.js`：多开前 BIN 认证与启动参数组装；确认认证完成后才创建 WebView。
- `ios-cocos/cocos-project/src/ios2-login.js`：确认 WebKit `/login/authuser` 能消费实例注入的认证响应。

## 修改原则

1. 先画清时序：选择 BIN -> 原生认证 -> 保存每个实例的认证响应 -> 创建多个 WebView -> WebView 发起 HSDK 登录。重复弹窗通常说明最后一步错误地回到了文件选择器。
2. 不要只删除弹窗调用；同时检查 HSDK 登录完成回调、`sdk-get-userId`、实例账号映射和退出清理，确保每个请求都闭环到原始实例。
3. 共享的 `s_ios2SDKLoginPending`、`s_ios2SDKLoginAction`、`s_ios2SDKLoginInstanceID` 只能用于非多开或兼容路径。多开回调应同步完成，避免下一个实例覆盖等待状态。
4. 实例身份必须通过桥接消息显式传递，不能从当前可见 WebView、全局最后登录账号或数组下标推断。
5. 保持 WebKit 多开数量限制（当前为 2 到 4 个）和 Cocos 极速行为不变；修改仅围绕认证复用与实例隔离展开。

## 验证

静态检查：

```sh
node --check ios-cocos/cocos-project/src/ios2-account-services.js
node --check ios-cocos/cocos-project/src/ios2-manager.js
node --check ios-cocos/cocos-project/src/ios2-login.js
git diff --check
```

使用 Xcode 构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -sdk iphonesimulator -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -quiet
```

真机/Xcode 调试冒烟测试：

1. 设置 `runtimeBackend` 为 `webkit`，选择 2 到 4 个不同 BIN，点击启动。
2. 观察原生日志和系统界面：启动过程中每个 BIN 只能选择一次，WebView 加载期间不得再次出现文件选择器。
3. 在每个实例触发 HSDK 登录和获取用户 ID，确认回调成功且账号 ID 与所选 BIN 一一对应。
4. 退出多开后再次启动另一组 BIN，确认没有沿用旧实例的认证或账号。
5. 同时回归 Cocos 极速单开，确认仍走 `loginBinFile:` 且不受多开认证分支影响。

模拟器构建成功不能替代真实设备验证；若未连接真机或无法运行 Xcode 调试，需在结果中明确说明。
