# CYZW 项目长期备忘（ios/Shell · macOS SwiftUI 游戏多开大厅）

## 技术基线
- macOS 大厅：SwiftUI + hiddenTitleBar 玻璃窗，工程 `ios/Shell/IOS2-Mac.xcodeproj`（scheme IOS2-Mac），部署目标 macOS 26.0。
- 构建/验证：`xcodebuild -project IOS2-Mac.xcodeproj -scheme IOS2-Mac -configuration Debug build`；改 UI 结构必须全量构建或 swiftc -typecheck（-parse 查不出语义错误）。
- 数据层：分组 ID 为 String（含 allID/ungroupedID 伪分组）；账号 .bin 存沙盒 AccountBins（AccountFileManager）；脚本存 IOS2Scripts（ScriptManager）。

## UI 约定（用户反复校准的偏好）
- 毛玻璃：NSVisualEffectView behindWindow 真·壁纸折射（VibrancyBackdrop），氛围光深藏蓝 #020713 系 + 星场/光束作 blur 证据层；压暗/提亮层必须带蓝相位，纯黑纯白会显灰。
- 分节结构：左侧中控台侧栏（账号/脚本/设置三段）+ 右侧恒为多开矩阵；账号与脚本同构（管理 UI 在侧栏内）。
- **macOS 悬停：一律用 AppKit tracking area 版 `hoverHighlight`（HoverHighlightModifier，MacMultiOpenManagerView.swift），禁止新写 onHover + @State 悬停——与点击存在竞态、会吞 mouseDown（表现为按钮要点几次才响应）。**
- **顶部 `TitleBarDragRegion`（28pt，`mouseDownCanMoveWindow`）是"点击黑洞"**：条带内的 mouseDown 会被 AppKit 消费成拖窗口，单击不动毫无反馈。它的矩形必须显式避开所有交互控件（现按侧栏显隐自适应：可见时只铺侧栏列宽 304，隐藏时只铺交通灯带 96 + 工作区控制条左侧让出同样宽度）。**避让方向优先选横向（左让），不要下移控制条——用户要求隐藏/显示侧栏两态顶部高度一致，纵向留白直接扣游戏画面高度。** 改任何控件的纵向位置/top padding 后必须重算与它的重叠。
- macOS 文件选择用 NSOpenPanel（ScriptImporter 模式）；SwiftUI .fileImporter 在深层子视图会静默不弹。
- sheet 内部模式受"入口 + 弹窗内切换"双重控制时用父级 Binding；弹窗尺寸只在 macBody 内定义一处。
- 同文件多次编辑必须串行（外置盘并行 Edit 有竞态/丢失风险），改完 sync 后验证。
- 侧栏卡片/控件统一配方（脚本页、设置页通用）：白玻璃卡片 white 0.055 填充 + 顶亮底暗描边渐变（连续圆角 10–12）、卡头 28×28 图标磁贴、状态用 Capsule(.continuous) 胶囊（选中=实色填充白字+微光，未选中=white 0.05 + 描边同色文字）、开关 mini switch + glowGreen #22B170、强调青 .cyan。新设置类 UI 直接抄这套，不要用系统 Picker/Toggle 默认外观。
- 游戏画质：MacRenderQuality（UserDefaults `ios2.renderQuality`，默认 high）→ bootstrapScript 注入 qualitySingle/qualityMulti → WebRuntime renderPixelRatio 决定画布像素比；档位只在实例启动时读取，改档需重启实例。
- **多开矩阵尺寸（2026-09-12 定稿）**：`MacMatrixFit.swift` 是唯一求解器（自动/手动都走它，输出 `MacMatrixLayout`）。卡片 = 顶栏 + 严格 9:16 游戏画面（高 = 宽×16/9），间距 14；自动模式 `min(按宽分配, 按高分配)` 取最大 + 单调剪枝 break。改矩阵尺寸/比例相关逻辑只动这个文件；`MacMatrixCanvasMetrics` 是画布留白唯一口径（外 24×2+底 20、内 16），改 padding 必须同步它，否则自动适配会溢出或留白。
- **「矩阵顶栏」有两层，别混淆**：① 大厅标题栏（「多开矩阵」标题条）——已改单行三档（标题 18/16/14pt、padding 随密度收，副标题「N 个活跃实例…」按用户要求删除，信息在 tooltip）；② 卡片控制条——三档 32/24/20pt（`MacMatrixFit.headerHeight(forInstanceCount:rows:)` 参与求解，顶栏每减 1pt 画面宽 +0.5625pt；两层条件缺一不可，只看行数的话双开 1 行触发不了）。两层都随 `matrixEntries.count` + `matrixLayout.rows` 收档并直接换算成游戏画面高度。
- **矩阵实例数 = `matrixEntries.count`**（运行账号 × WorkspaceItem 一一对应），适配计数/副标题/读数/ForEach 必须共用它。注意 `AccountGroup.all` 是「全部」伪分组，展平分组树时必须排除，否则每个运行中账号被数两遍（2 开算 4 开 → 按 4 列排版、高度占不满）。
- 尺寸模式开关：`@AppStorage("ios2.matrix.autoSize")`（默认自动）；点 ± 以当前实际宽度为起点自动切手动。网格用 `layout.gridWidth` 收紧 + `minHeight`=内容区高实现居中且不滚动。

## 键鼠同步 / 群控（2026-09-12 新增，JS IPC 方案，禁止 CGEvent/NSEvent 坐标模拟）
- 全部逻辑在 `ios/Shell/MacInputSync.swift`：`MacInputSyncEvent`（坐标恒为 0...1 归一化）+ `MacGameInstanceRegistry`（账号 ID → MacWebKitGameView 弱引用）+ `MacInputSyncController.shared`（master/receiver 状态 + 分发）+ `MacInputSyncScript.agent`（捕获器 + 回放器 + 波纹，二合一脚本）。
- **混合路由（2026-09-12 二次重构）**：🔗「参与同步」= 收件人 + 无主控时的发言人；👑「主控」一出现就把「发」的权限收归独占。
  - 有主控：主控 → 所有参与者；其它窗口静默（既不发也不捕获）。
  - 无主控：任一参与者 → 其余全部参与者（互相广播）；未参与者既不发也不收。
  - 真值表抽成**纯静态函数** `canSend/shouldCapture/routingTargets(master:receivers:sender:)`，可脱离 WebKit 单测（用脚本从源码抽出这几个函数编译跑真值表）。
- **防回灌是互相模式的生死线**：无主控时所有参与者都在捕获，回放出来的事件会被对方捕获器再抓一次 → 无限 ping-pong。解法是回放事件打 `__ios2SyncEcho` 标记，捕获器用 `guard()` 双闸门（capture 开关 + echo 标记）忽略。**只有原生真实事件会外发。**
- 捕获开关不再等价于「是否主控」，而是 `shouldCapture()` 派生；主控切换 / 参与开关切换 / 页面 didFinish / 实例重建 都要重算并写回页面（主控一变，所有参与者的捕获态都翻转）。
- **脚本必须 atDocumentStart 预注入到每个实例**，运行时只用 `setCapture(on)` 切角色——WKUserScript 无法在运行时追加。
- 回放派发到 `document.elementFromPoint()` 的元素（冒泡即可覆盖 document/window 上的监听，Cocos 挂 canvas 或 window 都收得到）；mousemove 走 rAF 合并 + Swift 侧 1/60s 节流双保险。
- 主窗口身份按**账号 ID**记，卡片重载（换 WebView）不会退位；只有账号级关闭（`WorkspaceViewModel.close`）才 `retire` 退位。
- UI：卡片 Header 的 👑/🔗 两个按钮 + 主控金色描边；顶部标题栏状态胶囊按 `mode` 三态显示——主控驱动（金色「主控 · N 跟随」，点击退位）/ 互相同步（青色「互相同步 · N 窗口」，点击全部关闭参与）/ idle 不占位。

## 游戏实例存储（踩过的坑）
- 游戏内设置（省电模式等）写在 `window.localStorage`，`cc.sys.localStorage` 就是它。因此 WebKit 实例**绝不能用 `.nonPersistent()`**，否则关窗即丢配置；也**不能用 `.default()`**，会和 App 内其它网页内容混在一起。
- 现行方案（MacWebKitGameWindow.swift，用户要求**所有账号共用一份配置**）：
  - `MacGameDataStore`：`WKWebsiteDataStore(forIdentifier:)`，共享模式用固定 seed `"shared-game-store"`；`.nonPersistent()` 与"按账号各存一份"都可通过 UserDefaults 开关回退（`ios2.gameStorage.persistentDataStore` / `ios2.gameStorage.sharedAcrossAccounts`）。
  - `MacGameSettingsStore`：原生镜像兜底自定义 scheme 不落盘，默认写 `Application Support/GameStorage/shared.json`（关闭共享时按账号各一份文件，已含一次性合并迁移）。
- App 未沙盒化，实际路径就是 `~/Library/Application Support/GameStorage/` 与 `AccountBins/`。
- 游戏真实配置键（已验证落盘）：`MUSIC_OPEN`、`SOUND_OPEN`、`VIBRATE_OPEN`、`SIMPLIFY_FLY_NUMBER`、`PRIVACY_OPEN`、`AFK_GAP`；账号相关键形如 `PREF#<角色uid>#GUIDE`、`SHOW_NIGHTMARE_WEEK_FACE-<uid>-...`，**游戏自己按 uid 区分**，所以全局共享一份存储与真机语义一致、不会串号。
- iOS 版 `WebKitInstance.configureWebView()` 仍是 `.nonPersistent()` 硬编码（policy.allowsStorage 只管 JS 能否访问、不管是否落盘）；用户已明确 iOS 不用管。
