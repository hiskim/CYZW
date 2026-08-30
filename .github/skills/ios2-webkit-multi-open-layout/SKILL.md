---
name: ios2-webkit-multi-open-layout
description: 维护 IOS2 WebKit 多开游戏窗口的均分布局、堆叠布局和悬浮群控按钮；适用于调整窗口尺寸、主次窗口切换、虚拟窗口、群控菜单或多开页面触摸隔离，不适用于 Cocos 极速单开布局。
---

# WebKit 多开窗口布局

## 目标

在 WebKit 模式下维护一个独立的群控总窗口，承载 2 到 4 个 `WKWebView` 子窗口。窗口布局、触摸行为、账号标识和群控操作必须保持一致，同时不覆盖或干扰 FairyGUI 账号管理首页。

## 核心约束

1. `IOS2Native.runtimeBackend` 严格为 `webkit` 时才启用多开布局；多开实例数量保持 2 到 4 个，单开仍使用单窗口登录流程。
2. 群控页面由 `groupContainer` 作为独立的全屏容器承载。创建、隐藏、关闭和布局多开窗口时，不要把子窗口添加到账号管理 FairyGUI 根节点或账号首页容器。
3. 均分布局使用固定槽位几何：2 开或 3 开时仍按 2x2 的四槽位计算，未使用槽位显示“增加多开”虚拟窗口；4 开时四个槽位全部为真实窗口。增加账号必须打开已有的 Bin 列表，并在群控窗口内完成选择，不得直接打开文件系统选择器。
4. 虚拟窗口的添加按钮必须在槽位内水平、垂直居中，文字需要在窄窗口中自适应，不能固定在右下角或被槽位裁掉。
5. 堆叠布局必须保留游戏窗口的宽高比例：一个 `primaryInstanceIndex` 为主窗口，主窗口较大；其他窗口在上方并排显示为较小缩略窗口。点击子窗口只交换主次，不把触摸事件传给子窗口内的游戏；只有点击主窗口才允许操作游戏。
6. 子窗口的触摸拦截层必须位于子窗口之上、主窗口之下，并在每次布局重排或主次交换后更新 `tag` 和 frame。关闭实例后要同步修正 `primaryInstanceIndex`。
7. 群控悬浮按钮属于 `groupContainer`，多开时显示在边缘并露出部分按钮；点击后移动到屏幕中间并打开群控菜单，空闲约 3.5 秒后自动回到边缘。按钮必须始终位于群控窗口层级之上，不能因隐藏后无法在群控页重新显示。
8. 多开顶栏保持精简，不显示与悬浮按钮重复的齿轮；单开 WebKit 顶栏恢复原有安全区下移、齿轮和快速切换 Bin 功能。单开时账号只显示在顶栏，不重复显示在游戏画面中央。
9. 多开窗口账号标签只显示去掉 `.bin` 后缀的名称，背景使用低不透明度，避免遮挡游戏；单开不得创建或显示该标签。
10. 群控菜单及“退出指定窗口”菜单必须消费弹窗外的触摸，不能因 iPad Action Sheet 的外部 dismiss 将触摸穿透到账号管理页，进而触发单开登录或关闭其他实例。

## 优先排查位置

```sh
rg -n "groupContainer|layoutInstances|primaryInstanceIndex|groupControlButton|groupControlTapped|tuckGroupControlButton|accountBadge|emptySlot|showGameMenu|showInstanceCloseMenu" \
  ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.mm
```

重点文件：

- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.mm`：`WKWebView` 实例生命周期、顶栏、群控容器、两种布局、标签、悬浮按钮和原生菜单。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`：WebKit 单开/多开认证、追加实例和返回账号管理页的原生桥。
- `ios-cocos/cocos-project/src/ios2-account-view.js`：FairyGUI 账号首页、多开选择页面和 Bin 列表 UI。
- `ios-cocos/cocos-project/src/ios2-account-presenter.js`、`ios2-account-services.js`：账号选择与登录用例编排；不要把窗口布局状态塞入 View。
- `ios-cocos/cocos-project/src/ios2-manager.js`：管理页生命周期、原生单开游戏工具栏和返回首页路由。

## 解耦与修改原则

1. `ios2-account-view.js` 只负责 FairyGUI 展示和发出 `login`、`multiOpen` 等意图；不要在其中操作 `WKWebView`、布局 frame、`jsb` 或 `IOS2Native`。
2. Presenter/Service 负责账号列表、Bin 选择和认证参数；原生 `IOS2GameWebView` 负责 WebKit 实例、窗口布局和群控触摸，不要通过全局“当前账号”推断子窗口身份。
3. 调整顶栏高度或容器层级时，同时检查 `layoutInstances` 的 `top`、安全区和所有弹窗 source view，避免窗口游戏 viewport 被意外拉伸或下移。
4. 修改堆叠布局时优先调整缩略窗口占用比例和间距，不改变主窗口的游戏宽高比；不要移除子窗口拦截层来“修复”触摸。
5. 关闭、重新登录、追加 Bin、切换布局和从群控返回首页都必须经过同一套实例清理与容器恢复流程，不能只隐藏某个 `WKWebView`。
6. 菜单操作应只影响明确的目标实例：布局切换修改布局状态，退出指定窗口只关闭选中的索引，关闭全部才调用总清理；禁止让菜单外点击触发 `showManager` 或单账号登录。

## 验证

静态检查：

```sh
node --check ios-cocos/cocos-project/src/ios2-account-view.js
node --check ios-cocos/cocos-project/src/ios2-account-presenter.js
node --check ios-cocos/cocos-project/src/ios2-account-services.js
node --check ios-cocos/cocos-project/src/ios2-manager.js
git diff --check
```

构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -sdk iphonesimulator -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -quiet
```

真机冒烟测试至少覆盖：

1. 2 开、3 开时均分布局显示四槽位，虚拟槽位提示完整且能在群控页打开 Bin 列表添加账号；4 开时没有虚拟槽位。
2. 堆叠布局中主窗口和子窗口比例稳定；点击子窗口只交换主次，点击主窗口才操作游戏。
3. 悬浮按钮边缘半隐藏、点击居中、约 3.5 秒后回边；从菜单或其他页面返回群控后按钮仍可见。
4. 单开顶栏显示账号、齿轮和快速切换 Bin；多开顶栏不显示齿轮，窗口标签无 `.bin` 且不明显遮挡游戏。
5. 打开群控菜单后点击弹窗外黑色区域，只关闭或保持菜单，不关闭多开实例、不启动单账号登录；菜单内的布局切换、退出指定窗口和关闭全部仍按目标执行。

模拟器构建成功不能替代真机触摸验证；若未连接设备，应明确记录未完成真机验证。
