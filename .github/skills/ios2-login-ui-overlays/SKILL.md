---
name: ios2-login-ui-overlays
description: 维护 IOS2 多开选择弹窗和登录后游戏顶栏/弹窗，适用于调整 2.png 风格、多开 bin 选择、Cocos/WebKit 顶栏一致性、齿轮菜单、切换 bin 列表、弹窗遮罩卡住或滚动异常；不用于重写认证协议本身。
---

# IOS2 登录 UI 浮层

## 目标

保持账号多开弹窗、WebKit 登录后顶栏、Cocos 登录后顶栏三处体验一致：浅色 iOS 风格、账号名左置、右侧蓝色图标、列表可滚动、弹窗可取消，并且关闭弹窗后游戏触摸必须恢复。

## 相关技能

涉及运行模式切换、Cocos/WebKit 路由或登录后游戏触摸无响应时，先读取 .github/skills/ios-cocos-runtime-modes/SKILL.md。

涉及账号首页架构、FairyGUI 生命周期、账号列表导入/删除/登录入口时，同时读取 .github/skills/ios2-fairygui-account/SKILL.md。

涉及 WebKit 多开认证复用、HSDK 重复弹选择器或实例串线时，同时读取 .github/skills/ios2-webkit-multi-open-auth/SKILL.md。

## 代码位置

- ios-cocos/cocos-project/src/ios2-account-view.js：FairyGUI 账号首页与 _showMultiOpen 多开选择弹窗。
- ios-cocos/cocos-project/src/ios2-manager.js：Cocos 极速模式登录后的 gameToolbar、齿轮菜单、信息弹窗和切换 bin 列表。
- ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.mm：WebKit 登录后的原生顶栏、系统菜单和切换 bin action sheet。
- ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm：原生 bin 记录排序和 IOS2ManagedBinRecords / IOS2LoginManagedBin 这类桥接能力。

## 多开弹窗约束

1. 多开选择弹窗属于账号首页 UI，优先在 ios2-account-view.js 的 _showMultiOpen 内维护；不要把 jsb、IOS2Native、认证或 HSDK 逻辑写进 View。
2. 弹窗使用 FairyGUI 能力实现，列表使用 fgui.GList 和 setupScroll(verticalScrollBuffer())，bin 多时必须可拖动滚动。
3. bin 列表按账号页已有记录顺序展示；如果要调整排序，优先改仓储或原生列表排序，不要只在弹窗里临时硬编码。
4. 选中数量必须和当前产品要求一致；当前多开弹窗要求选择 2 个 bin 后才显示并允许点击“启动”。
5. 弹窗必须有明确“取消”入口，并且取消只关闭弹窗，不触发登录或改变已登录游戏状态。

## 登录后顶栏约束

1. WebKit 登录后顶栏在 IOS2GameWebView.mm 用原生 UIKit 实现，因为 WKWebView 位于 Cocos 节点之上；Cocos 节点顶栏不会可靠显示在 WebKit 游戏上方。
2. Cocos 极速登录后顶栏在 ios2-manager.js 用轻量 Cocos 节点实现；登录或恢复游戏前必须隐藏/停用 FairyGUI 账号管理根节点，避免管理 UI 截获游戏触摸。
3. 顶栏视觉保持一致：浅蓝白背景、左侧账号名去掉 .bin 后缀、右侧依次显示齿轮、人头/双人、信息、右箭头，图标使用 iOS 系统蓝或同色 Cocos 自绘图形。
4. 齿轮菜单提供“重新登录”和“关闭”；人头/双人按钮打开切换 bin 列表；信息按钮只显示当前账号信息；右箭头返回/关闭行为要保持现有产品语义。
5. Cocos 顶栏只能拦截顶栏和当前弹窗区域的触摸。弹窗关闭后，不得留下全屏节点、遮罩、cc.BlockInputEvents 或可触摸 FairyGUI 根节点挡住游戏。

## Cocos 弹窗防卡死规则

1. 不要在 cc.Node 上写 node.addChild(child).setPosition(...)。Cocos Creator 2.4 的 cc.Node.addChild 不返回 child，这会抛出 setPosition undefined，导致遮罩残留并卡住游戏触摸。必须先创建 child，先 setPosition，再 addChild。
2. 顶栏按钮回调应包一层异常保护；如果菜单或列表创建失败，先调用 _dismissGamePopup() 清理遮罩，再记录错误。
3. 弹窗外层可以使用半透明遮罩承接“点击外部关闭”，但不要给全屏容器加永久性的 cc.BlockInputEvents。关闭弹窗必须 remove 整个 popup layer 并清空引用。
4. 面板内部需要停止事件冒泡，避免点菜单项或滚动列表时触发外部关闭；列表行点击要区分拖动和点击，拖动时不能触发切换登录。
5. 切换 bin 列表使用稳定的正坐标布局，内容高度大于视口时交给 cc.ScrollView 处理，避免出现白板列表或不可拖动列表。

## 验证

从仓库根目录执行静态检查：

- node --check ios-cocos/cocos-project/src/ios2-manager.js
- node --check ios-cocos/cocos-project/src/ios2-account-view.js
- node --check ios-cocos/cocos-project/src/ios2-account-services.js
- node --check ios-cocos/cocos-project/src/ios2-account-presenter.js
- node --check ios-cocos/cocos-project/src/ios2-script-page.js
- node --check ios-cocos/cocos-project/src/ios2-config-page.js
- node --check ios-cocos/cocos-project/src/ios2-bin-page.js
- git diff --check

检查 Cocos 登录后 UI 路径不能再有危险链式写法：

- rg -n "addChild.*setPosition" ios-cocos/cocos-project/src/ios2-manager.js

该命令应无输出。使用 Xcode 构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -sdk iphonesimulator -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -quiet
```

手动冒烟测试至少覆盖：WebKit 多开弹窗可滚动且取消可关闭；Cocos 极速单账号登录后顶栏图标与 WebKit 风格一致；点击齿轮、切换 bin、信息弹窗后都能取消关闭；关闭后游戏区域触摸恢复；选择其他 bin 后能重新登录。
