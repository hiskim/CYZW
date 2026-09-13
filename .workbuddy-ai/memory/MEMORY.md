# CYZW 项目长期记忆

## 客户端版本号（4 处硬编码，改版要一起动）

- `ios/Shell/MacCDNResourceManager.swift` 的 `manifestVersion`（拉清单的 version 参数）
- `ios/Shell/MacWebKitGameWindow.swift` HSDK `game-init` 回包的 `gameVersion`
- `ios-cocos/cocos-project/jsb-adapter/game-defines.js` 的 `GAME_VERSION` / `CODE_VERSION` / `RESOURCE_MANIFEST_VERSION`
- `ios-cocos/.../ios/AppController.mm` 的 `kIOS2GameVersion`
- 服务端 `POST https://xxz-xyzw.hortorgames.com/login/manifest?platform=hortor&version=<v>`
  按**白名单**返回代码包，不在名单里就没有 bundleVers（2026-09 实测：0.28~0.33、0.35 有值，
  0.34/0.36+ 为空；0.33.0-ios → codeVersion 2.45.3，是最新一档）。换版本前先用这条命令探一遍。

## 原生路径 vs WebKit 路径的版本状态（活动/功能开关的常见坑）

- 原生入口 `cocos-project/main.js` 拿到 manifest 后会落地
  `cc.sys.manifestResult.rawData`、`cc.sys.ios2ResourceVersion{codeVersion,resourceVersion,battleVersion}`，
  并用 getter 锁死 `window.BATTLE_VERSION`；远端 launcher 与活动代码正是从这些全局读版本元数据。
- WebKit 入口 `cocos-project/src/ios2-web-boot.js` 必须同步做到同样三件事
  （已补 `installManifestVersionState`）。以后在这两个入口加「manifest 派生状态」时，**两边都要加**，
  否则只有 macOS 端出现「版本不对 / 功能不开放」。
- Xcode 的 "Copy WebRuntime" 构建阶段把 `cocos-project/src`、`assets`、`jsb-adapter/game-defines.js`
  拷进 app，改这些源码需要重新构建才生效。

## 多开矩阵布局（用户明确的设计约束）

- **单实例游戏窗口必须严格保持 9:16**。禁止用横向填充、裁切上下留白、
  或独立缩放宽高比来「提高利用率」——这类方案已被明确否决。
- 提高有效显示面积的唯一手段是**压缩包裹层边距**。当前三层均为 1px：
  - 游戏窗口 ↔ 画布边缘 = 1px
  - 画布 ↔ 大厅窗口边缘 = 1px
- 边距单一真源：`ios/Shell/MacMatrixFit.swift` 的 `MacMatrixCanvasMetrics`
  （`outerHorizontal` / `outerBottom` / `inner`）。
  `MacMultiOpenManagerView.swift` 的 padding 与 `minHeight` 全部引用它，
  改常量即可，**不要就地写死数值**（两处口径不一致会让卡片尺寸算错）。
- 画布贴齐窗口后不要挂外投影（会被窗口边界裁成脏边），1px 渐变描边足够。
- 顶部控制条（`workspaceHeader` 及未来同类）里所有放进 `HStack` 的 `Text`
  **必须** `.lineLimit(1)`，必要时加 `.minimumScaleFactor(0.6~0.8)`。
  否则画布窄时 SwiftUI 会把 Text 拆成单字符一列竖排，把控制条撑到几十 pt
  高，直接吃掉下方 `GeometryReader` 的可用高度（9:16 反推的画幅也跟着缩）。
- 中文 UI 字符串里嵌套引用一律用 `「」` 或弯引号 `""`，**不要**用直引号 `"`——会与外层字符串边界冲突导致 parse 失败。
- 卡片内游戏画面本来就贴齐卡片边缘，改利用率时不要去动 cell 内部。

## WKURLSchemeHandler 生命周期（踩过两次坑）

- 任务停止后回传（`didReceive`/`didFinish`/`didFailWithError`）会抛
  `NSInternalInconsistencyException: This task has already been stopped`。
- 抑制必须按**任务粒度**：只吞 `webView(_:stop:)` 明确通知过的 task
  （`stoppedTasks: Set<ObjectIdentifier>`）。**绝不能**按实例粒度一刀切
  （`stopAll()` 设个 `isStopped` 就全丢）——`stop()` 可能早于导航发生
  （deinit / 池驱逐），那时主文档请求会被一起拦掉，表现为「全部实例白屏、无法登录」。
- `stopAll()` 的顺序：先对仍在 pending 的任务 `didFailWithError` 收尾（不收尾＝资源永久挂起），
  再把剩余 token 并入 `stoppedTasks`，最后才 `stopLoading()`。
- 日志里大片的 `com.apple.linkd.autoShortcut` / `pboard` / `launchservicesd` /
  `coreservicesd` / `AudioComponentRegistrar` 报错是 WebContent 沙盒噪音，与业务崩溃无关，别被带偏。
- `MacWebKitGameView.stop()` 的调用面很广（关实例、池驱逐、deinit），可能早于导航发生。
  任何「停止后就不回传」的逻辑都要能容忍这一点，否则会把首次导航的主文档一起干掉。
  排错时可在 stop / deinit / stopAll 打 `Thread.callStackSymbols`（debug 档）定位调用方。

## 日志约定

- **不要再写裸 `NSLog` / `print`**，一律用 `ios/Shell/MacLog.swift` 的
  `MacLog.error/warn/info/debug/verbose`；等级口径（verbose = 每资源一条的流水）
  写在 `MacLogLevel` 的文档注释里，归类前先看一眼。
- 昂贵的实参（`sha256`、拼大字符串）必须先用 `MacLog.isEnabled(.xxx)` 挡住，
  否则关掉日志只省了打印、没省掉计算。
- 新增 Swift 文件必须手工登记 `ios/Shell/IOS2-Mac.xcodeproj/project.pbxproj`
  （该工程逐个列源文件：PBXBuildFile / PBXFileReference / Shell group / Sources phase），
  否则 Xcode 里不参与编译。
- 校验编译：`xcodebuild -project … -derivedDataPath /tmp/xxx build`
  （不要写进仓库里的 build 目录）。

## 协作约定

- 用户只保留源码改动，从 Xcode 自行运行；**不要**刷新仓库里
  `ios/Shell/build/Debug/IOS2-Mac.app` 的构建产物（会把 dylib / Assets.car /
  _CodeSignature 等未跟踪文件带进仓库，旧快照曾因此整包回退）。
- Commit 风格：`type(mac): 一句话摘要` + 空行 + 分点详述根因与修法。
- `.gitignore` 已用 `xcuserdata/` + `*.xcuserstate` 覆盖 Xcode 用户态数据
  （2026-09-13 起，并对已入库的 `UserInterfaceState.xcuserstate` 做了
  `git rm --cached`）。以后再出现 xcuserstate 变动，是本地索引残留，
  直接 `git rm --cached <path>` 即可，不要改回具体路径的忽略规则。
