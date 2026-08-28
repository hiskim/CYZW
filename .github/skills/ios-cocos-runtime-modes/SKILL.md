---
name: ios-cocos-runtime-modes
description: 维护 IOS2 原生 Cocos 项目中的 Cocos 极速与 WebKit 多开模式隔离，适用于处理脚本加载、多开、登录路由、运行模式切换，或登录后游戏界面触摸无响应问题。
---

# IOS2 Cocos 运行模式

## 目标

维护 IOS2 原生 Cocos Creator 2.4.x 项目中 `Cocos 极速` 与 `WebKit 多开` 两套运行模式的边界，避免原生 Cocos 模式误加载 JS 脚本、误暴露多开入口，或登录后被管理 UI 截获触摸事件。

## 核心约束

1. 以原生桥 `IOS2Native.runtimeBackend` 作为运行模式的唯一事实来源。只有返回值严格等于 `webkit` 时才启用 WebKit 行为；其他值都视为原生 Cocos 模式。
2. `Cocos 极速` 是单实例原生 JSB 游戏路径。它必须使用 `loginBinFile:` 认证，不得安装 `__ios2ScriptRuntime`，不得运行 `_runEnabledScriptsAfterLogin`，不得调用 `showScripts:`，也不得暴露或支持多开控件。
3. `Cocos 极速` 登录成功后，在启动或恢复游戏前必须隐藏或停用 FairyGUI / 账号管理根节点。管理层如果仍处于可见或可触摸状态，可能会压在游戏上方，导致游戏界面点击无反应。
4. `WebKit 多开` 是唯一可以调用 `loginBinFiles:scriptsJSON:manifestJSON:`、传递已启用导入脚本、显示 JS 脚本页面、打开 `IOS2ScriptWebView`、以及启动 2 到 4 个游戏实例的路径。
5. 保持退出登录和重置流程完整，确保从游戏返回时管理 UI 与 FairyGUI 根节点能恢复。

## 优先排查位置

优先用 `rg` 搜索这些锚点：

```sh
rg -n "runtimeBackend|loginBinFile:|loginBinFiles:scriptsJSON:manifestJSON:|__ios2ScriptRuntime.install|_runEnabledScriptsAfterLogin|showScripts:|selectScriptFile|WebKit 多开|Cocos 极速" ios-cocos
```

常见代码位置：

- `ios-cocos/cocos-project/src/ios2-account-services.js`：负责单账号登录与 WebKit 登录路由，并防止原生模式加载脚本。
- `ios-cocos/cocos-project/src/ios2-account-presenter.js`：只在服务层实际需要脚本时传递脚本记录。
- `ios-cocos/cocos-project/src/ios2-account-view.js`：只在 WebKit 模式显示 `多开` 和 `JS 脚本管理`。
- `ios-cocos/cocos-project/src/ios2-manager.js`：负责页面路由、原生游戏启动时隐藏或停用 FairyGUI、以及避免 Cocos 模式登录后执行脚本。
- `ios-cocos/cocos-project/src/ios2-script-page.js`：将脚本列表、导入和执行都限制在 WebKit 模式。
- `ios-cocos/cocos-project/src/ios2-bin-page.js`：如果旧版 Bin 页面仍可进入，需要同步修复其中可能安装脚本运行时的登录路径。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`：在 Objective-C 原生桥层为 `showScripts:`、`selectScriptFile`、`loginBinFiles:scriptsJSON:manifestJSON:` 增加兜底防护。

## 修改原则

1. 模式判断要覆盖多层入口：可见 UI、JavaScript service / presenter、旧页面、以及 Objective-C 原生桥。只隐藏按钮不够，因为 JS 或原生方法仍可能被其他路径调用。
2. 多处依赖运行模式时，优先封装 `runtimeBackend()` 或 `_runtimeBackend()` 这类小 helper，避免散落重复桥接调用。
3. 在 Cocos 模式下，启用脚本列表应返回空数组，登录应直接走原生登录。不要为了登录去读取脚本内容，也不要安装脚本运行时。
4. 在 WebKit 模式下，保留已有行为：单账号 WebKit 登录仍可使用 `loginBinFiles:scriptsJSON:manifestJSON:` 打开全屏 WKWebView，多开仍默认限制为 2 到 4 个账号，除非用户明确要求调整。
5. 如果文档描述了运行模式行为，应同步更新说明，明确 Cocos 是单开且不加载导入 JS，WebKit 才拥有脚本和多开能力。

## 验证

从仓库根目录执行语法检查：

```sh
node --check ios-cocos/cocos-project/src/ios2-account-services.js
node --check ios-cocos/cocos-project/src/ios2-account-view.js
node --check ios-cocos/cocos-project/src/ios2-manager.js
node --check ios-cocos/cocos-project/src/ios2-script-page.js
node --check ios-cocos/cocos-project/src/ios2-config-page.js
node --check ios-cocos/cocos-project/src/ios2-bin-page.js
```

最终检查：

```sh
git diff --check
git status --short
```

条件允许时运行相关 iOS 构建或 Xcode target；如果无法运行，需要在最终说明中明确未做构建/真机验证。

手动冒烟测试应覆盖：`Cocos 极速` 单账号登录和游戏内点击响应；Cocos 模式下不显示 JS 脚本和多开入口；`WebKit 多开` 脚本导入/加载；WebKit 单账号登录；WebKit 2 到 4 账号多开。
