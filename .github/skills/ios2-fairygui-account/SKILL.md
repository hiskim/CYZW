---
name: ios2-fairygui-account
description: '维护 ios2 Cocos Creator 2.4.9 的 FairyGUI 账号管理首页。Use when: 修改账号列表、导入、删除、bin 登录、首页导航、FairyGUI 生命周期，或排查 UI 与原生登录逻辑耦合问题。'
argument-hint: '描述要修改的账号管理 UI 或登录流程'
user-invocable: true
disable-model-invocation: false
---

# ios2 FairyGUI 账号管理

## 目标

维护 App 首屏账号管理功能，同时保持 FairyGUI UI、页面编排、账号存储和认证传输相互解耦。

## 代码位置

开始工作时先定位到账号代码目录：

```sh
cd ios-cocos/cocos-project/src
```

核心文件：

- `ios2-account-view.js`：纯 FairyGUI View，只渲染数据并发送用户操作。
- `ios2-account-presenter.js`：协调 View、账号仓储和登录服务。
- `ios2-account-services.js`：封装 `IOS2Native` 原生账号操作和登录调用。
- `ios2-login.js`：拦截游戏 `/login/authuser` 请求并接收认证结果。
- `ios2-manager.js`：挂载 FairyGUI、切换页面，并在认证成功后启动游戏。
- `../main.js`：按顺序加载 FairyGUI 和账号管理模块。
- `vendor/fairygui.js`：锁定到 Cocos Creator 2.4 分支的 FairyGUI 运行库。
- `vendor/FAIRYGUI-LICENSE.txt`：FairyGUI MIT 许可证。

原生桥位于：

- `../frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`

## 架构约束

1. `ios2-account-view.js` 不得引用 `jsb`、`HSDK`、`IOS2Native`、`loginBinFile` 或认证协议。
2. View 的输入是普通账号数组；输出仅为 `importAccounts`、`login`、`remove`、`openScripts`、`openConfig` 等用户意图。
3. Presenter 负责状态文案、忙碌状态和用例编排，不直接执行 `jsb.reflection`。
4. 所有原生反射调用集中在 `ios2-account-services.js`。
5. `/login/authuser` 的响应适配继续由 `ios2-login.js` 管理，不移入 UI 或 Presenter。
6. 只有 `ios2-manager.js` 可以在认证成功后调用 `__ios2StartGame`。
7. App 首屏必须停留在账号管理页，用户选择账号前不得自动启动游戏。
8. FairyGUI `GRoot` 必须位于启动场景之上，并在登出重启时正确销毁和重建。

## 修改流程

1. 阅读请求涉及的最小文件范围，并先判断修改属于 View、Presenter、Service 还是登录传输层。
2. UI 外观、布局、按钮和列表渲染只修改 `ios2-account-view.js`。
3. 状态流转和用户操作编排修改 `ios2-account-presenter.js`。
4. 文件列表、导入、删除和原生登录入口修改 `ios2-account-services.js`；若原生 API 不足，再修改 `AppController.mm`。
5. 页面挂载、游戏启动、登出重建和原生回调转发修改 `ios2-manager.js`。
6. 新模块必须在 `main.js` 的 `managerFiles` 中按依赖顺序加载：FairyGUI、Service、View、Presenter、Manager 模块。
7. 保持现有 JS 脚本页和配置页行为不变，除非请求明确涉及它们。

## 验证

从仓库根目录执行语法检查：

```sh
cd ../../../
node --check ios-cocos/cocos-project/main.js
node --check ios-cocos/cocos-project/src/ios2-manager.js
node --check ios-cocos/cocos-project/src/ios2-account-services.js
node --check ios-cocos/cocos-project/src/ios2-account-presenter.js
node --check ios-cocos/cocos-project/src/ios2-account-view.js
node --check ios-cocos/cocos-project/src/vendor/fairygui.js
```

确认 View 没有跨层依赖：

```sh
grep -En 'jsb|reflection|HSDK|loginBinFile|IOS2Native' \
  ios-cocos/cocos-project/src/ios2-account-view.js
```

该命令应无输出。

使用 Xcode 构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -sdk iphonesimulator -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -quiet
```

运行验证首次启动时，应先卸载设备中的旧 App 再安装。普通覆盖安装会保留 Documents 和认证状态，可能直接进入游戏，造成首页未挂载的误判。

最终检查：

```sh
git diff --check
git status --short
```

不要自动提交或推送；等待用户明确要求。
