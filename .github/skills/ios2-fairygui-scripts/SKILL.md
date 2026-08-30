---
name: ios2-fairygui-scripts
description: 维护 IOS2 WebKit 多开模式下的 FairyGUI JS 脚本管理页面，适用于脚本导入、开关与作用域、脚本执行、列表滚动、操作弹窗和批量删除等功能。
---

# IOS2 FairyGUI JS 脚本管理

## 目标

保持 JS 脚本管理页与 IOS2 的浅色 FairyGUI 管理界面一致，并保证脚本配置、WebKit 多开执行和原生文件桥接之间的状态一致。页面只属于 `WebKit` 模式；`Cocos 极速` 模式不能加载或执行导入脚本。

## 代码位置

- `ios-cocos/cocos-project/src/ios2-script-page.js`：页面渲染、脚本状态、FairyGUI 列表/弹窗、导入删除和执行记录筛选。
- `ios-cocos/cocos-project/src/ios2-manager.js`：页面路由、管理层生命周期和 `parts.scripts` 的挂载。
- `ios-cocos/cocos-project/src/ios2-account-presenter.js`：单开/多开登录前按环境请求可执行脚本。
- `ios-cocos/cocos-project/src/ios2-account-services.js`：向原生桥传递脚本 JSON 的登录服务。
- `ios-cocos/cocos-project/src/ios2-script-runtime.js`：脚本与 Cocos 游戏模块之间的兼容桥，不负责页面状态。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`：脚本文件选择、列表、读取内容、删除和 `IOS2Native` 导出方法。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2ScriptWebView.mm`：在 WKWebView 中加载脚本源码并转发游戏请求。

涉及运行模式或登录路由时，同时读取 `.github/skills/ios-cocos-runtime-modes/SKILL.md`；涉及账号首页入口或 FairyGUI 根节点生命周期时，同时读取 `.github/skills/ios2-fairygui-account/SKILL.md`。

## 状态契约

脚本记录保存在 `ios2.scripts`，常用字段为：

```js
{ name: 'example.js', enabled: false, scope: 'single', size: 1234 }
```

- 新导入脚本默认 `enabled: false`、`scope: 'single'`，已有同名脚本要保留原来的开关和作用域。
- `ios2.scripts.globalEnabled` 是所有脚本的总开关。关闭时只能阻止加载，不能修改任何脚本的 `enabled` 或 `scope`。
- `ios2.scripts.multiGate` 是多开执行门禁。关闭时多开环境返回空脚本列表，但不修改脚本自身状态。
- 单开环境加载所有 `enabled` 脚本；多开环境只加载 `enabled` 且 `scope === 'multi'` 的脚本，并且必须同时通过总开关和多开门禁。
- 页面状态更新应通过 `_updateScriptVisuals` 原地完成；切换开关、修改作用域或选择批量项不能调用 `_showScripts` 重建整个页面，避免滚动位置跳回顶部。

## FairyGUI 页面约束

1. 页面使用 `fgui.GComponent`、`GGraph`、`GTextField` 和 `GList` 绘制，背景使用 `common.COLORS.background` 的白色，不要引入独立深色页面主题。
2. 顶部两个控制卡片并排展示：JS 引擎总开关和多开全局门禁。当前基准尺寸为约 `136px` 高，启用时显示绿色状态、绿色 `5px` 描边，禁用时使用中性描边和暂停说明。
3. 开关使用滑动样式：绿色轨道表示开启、浅灰轨道表示关闭、白色圆点左右移动。可见轨道约 `72x42`；触摸区域应大于可见轨道，当前基准约 `112x76`。
4. 说明文本、标题颜色、描边和开关状态必须在切换时同步更新。不要只改数据或只改开关图形而留下旧说明。
5. 脚本列表使用 `GList` 和 `setupScroll(verticalScrollBuffer())`。列表在 legacy Cocos content node 下时，要显式把 Cocos 触摸事件转发给 FairyGUI `ScrollPane`，并保持与账号页相同的拖动方向。
6. 列表行当前基准高度约 `94px`。开关附近的触摸区域必须优先切换脚本，并阻止脚本操作弹窗；建议通过共享切换回调和行右侧安全区处理，不要扩大热区到脚本名称区域。
7. 脚本作用域标签使用不同颜色：`仅单开` 使用 `COLORS.accent` 蓝色，`单开 + 多开` 使用紫色。原地修改作用域时同时更新标签文字和 `color`。
8. 点击脚本行主体才打开操作弹窗，弹窗包含“仅单开生效”“单开 + 多开生效”“禁用”“删除”四项；删除操作使用危险色并调用原生删除桥。
9. 批量删除模式必须支持批量入口、全选/取消全选、逐行复选框和删除已选数量。批量选择只改变选择映射，不要误改脚本启用状态。
10. 不在页面顶部长期显示“当前：多开模式”之类模式提示，也不要把过期的导入失败状态固定在页面底部；状态提示只反映当前操作。

## 触摸与刷新原则

- FairyGUI 的 `onClick` 与 legacy Cocos 节点触摸桥接不能造成一次操作执行两次；需要桥接时，明确停止事件传播并保证回调幂等。
- 脚本开关点击必须只切换 `script.enabled`、持久化并更新现有节点。记录并恢复 `scrollPane.posY` 只用于确实需要重建的场景，例如文件列表异步刷新。
- 滚动拖动期间不要弹出脚本操作窗，也不要切换脚本。处理 `scrollPane.isDragged` 和触摸取消事件。
- 不要给页面按钮设置不存在的 `fgui.UIConfig.tooltipsWin`；使用 tooltip 前先确认配置存在，否则会在运行日志中产生 `UIConfig.tooltipsWin not defined`。

## 原生桥接边界

- 只通过 `IOS2Native.selectScriptFile`、`listScriptFiles`、`scriptFileContent:`、`deleteScriptFile:` 等现有方法操作文件，不在 JS 页面直接访问 iOS 文件系统。
- 原生回调 `onScriptFiles` 应合并同名脚本的已有状态，再保存并刷新列表；导入失败、删除失败要回传可读状态。
- `_enabledScriptRecords(errors, environment)` 是登录执行前的统一筛选入口。不要在账号 View 中重复筛选，也不要绕过总开关、多开门禁或作用域判断。
- 脚本源码应在 WKWebView 中执行，Cocos 侧只提供兼容桥和游戏请求转发；不要在 Cocos 极速路径安装或运行脚本运行时。

## 验证

从仓库根目录至少执行：

```sh
node --check ios-cocos/cocos-project/src/ios2-script-page.js
git diff --check
python3 /Users/gg/.codex/skills/.system/skill-creator/scripts/quick_validate.py .github/skills/ios2-fairygui-scripts
```

设备验证应覆盖：总开关关闭时单开/多开都不加载脚本且子状态不变；多开门禁关闭时只阻止多开；单开/多开作用域分别正确筛选；开关附近点击不弹窗且滚动位置保持；拖动列表方向与账号页一致；标签文字和颜色同步；全选、部分选择和批量删除结果正确；日志中没有 `UIConfig.tooltipsWin not defined`。
