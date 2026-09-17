# LobbyCoreSystem · macOS 游戏多开大厅（全新实现）

参考 `new3.txt` 规格书 2.0 与上一代 macOS 大厅（`ios/Shell/IOS2-Mac`）的实战经验，
在全新目录用全新代码实现的 Cocos 轻客户端同屏多开大厅。**代码与命名零 `ios2` 残留**
（仅存的 `ios2Game` / `__IOS2_GAME_INSTANCE__` / `ios2-` 前缀是 WebRuntime 页面侧
硬编码的外部契约，集中在 `LobbyConfiguration` 常量区声明，见文件内注释）。

## 当前状态：阶段 1 —— 游戏大厅 + 登录 ✅

- **账号库**：导入 / 删除 `.bin` 凭据（NSOpenPanel 多选），与上一代大厅**共用**
  `~/Library/Application Support/AccountBins`，已导入账号开箱即用。
- **登录**：选账号 → `.bin` 提交 `/login/authuser` 预认证 → WebKit 实例装载
  `game-res://app/index.html`，XHR 拦截器把预认证响应喂给游戏登录请求，
  HSDK 桥应答 `game-init` / `user-tokenlogin` 等登录链路。
- **多开矩阵**：9:16 严格比例自动适配（闭式解 + 单调剪枝），启动并发闸门
  （2 路 + 90s 超时），实例池化管理（SwiftUI 格子重建不重启游戏）。
- **能耗仲裁**：焦点实例满帧出声，非焦点降帧（15 FPS）静音（帧率走
  「暂停 → 等旧循环退出 → 重启」路径，规避 Cocos 2.4.9 `setFrameRate` 缺陷）。
- **共享 CDN 资产仓**（actor）：下载合并、跨实例内存副本、磁盘缓存索引、
  404 风暴防护、清单持久化回退。
- **分组管理**：自定义分组 CRUD（新建/重命名/改色/排序/删除，删除可选连成员）、
  归属表按 `账号ID → 分组ID` 记录（改名免搬家）、侧栏分组筛选条、账号右键
  「移动到分组」、分组持久化 `Application Support/GameLobby/groups.json`、
  矩阵按「未分组 → 分组定义序」排列、卡片与侧栏按分组色着色。
- **脚本管理**：.js 导入/删除/三态作用域（禁用/单开/单多开），总开关 + 多开
  门禁双闸（语义与上一代一致），实例启动时按环境 atDocumentEnd 注入；脚本目录
  与上一代共用 `IOS2Scripts`。
- **游戏加强**（设置页 · 游戏加强）：首项为**十殿加速**：
  改写 `NightmareBattlePanel.DEFAULT_TIMESCALE` 让十殿试炼战斗动画整体加速
  （只改画面节奏，不改战斗结算）。代理脚本 atDocumentStart 预注入 + 哨兵幂等，
  开关 / 倍率（1...1000，推荐 100）即时落 UserDefaults 并广播全部存活实例，
  新实例在文档就绪时自行下发；`__require` 未就绪时走 500ms × 120 有界轮询补装钩子。
- **键鼠同步（群控）**：纯 JS IPC 方案（坐标 0...1 归一化，禁止 CGEvent 模拟），
  混合路由（👑 主控独占发送 / 🔗 无主控时参与者互相同步），路由以账号分组为
  隔离边界；防回灌（ECHO 标记双闸门）、mousemove rAF 合并 + 原生 1/60s 节流
  双保险、波纹特效；卡片 👑/🔗 按钮 + 主控流光描边 + 标题栏状态胶囊三态；
  重载不退主控（按账号 ID 记身份），账号级关闭才退休。
- **游戏内配置镜像**：localStorage 实时回传 + 20s 兜底快照，与上一代大厅共用
  `GameStorage` 目录。
- **存储隔离策略**（规格 §2.2）：默认 `WKWebsiteDataStore(forIdentifier:)` 账号
  独立容器，可切换全局共享 / 不持久化（设置页）。

## 构建与运行

```bash
# 命令行构建（无签名，Debug）
xcodebuild -project GameLobby.xcodeproj -scheme GameLobby -configuration Debug build

# 产物（DerivedData）
open ~/Library/Developer/Xcode/DerivedData/GameLobby-*/Build/Products/Debug/潮音之王.app
```

或直接用 Xcode 打开 `GameLobby.xcodeproj`，选 GameLobby scheme ⌘R。

### App 名称：改名要动三处（第四处 Xcode 自己做）

显示名「潮音之王」实际由 `PRODUCT_NAME` 决定，改名时同步这些地方：

| 位置 | 键 / 变量 | 作用 |
|---|---|---|
| `GameLobby.xcodeproj`（**Debug + Release 两处**） | `PRODUCT_NAME` | 产物文件名 `潮音之王.app`、可执行文件 `MacOS/潮音之王`；`CFBundleName` / `CFBundleExecutable` 自动跟随 |
| `App/Info.plist` | `CFBundleDisplayName` | Dock / 启动台 / 应用菜单 / 关于窗口显示的名字 |
| `Scripts/build-dmg.sh` | `PRODUCT_NAME` | 派生 `APP_NAME` 与 `lipo` 读架构的路径 |
| `GameLobby.xcscheme` | `BuildableName` | **Xcode 自动同步**，不用手改（中文会存成 `&#x6f6e;&#x97f3;…` 这样的 XML 数字字符引用，属正常） |

> ⚠️ **只改 `CFBundleDisplayName` 不够**：Finder 显示的是 .app 的**文件系统名**，
> 不动 `PRODUCT_NAME` 的话，看起来就还是旧名字。
>
> ⚠️ pbxproj 里还有一批 `PRODUCT_NAME = "$(TARGET_NAME)"`（那 5 个静态库），
> 是给 `libLobbyDomain.a` 之类用的，**不要一起改**。
>
> 侧栏标题「游戏大厅」是功能区标题，**刻意不跟随** app 名。

### 打包 dmg 安装包

```bash
./Scripts/build-dmg.sh                    # Release / 双架构 → build/dist/潮音之王-<版本>.dmg
./Scripts/build-dmg.sh --arch native      # 只编本机架构（快一半）
./Scripts/build-dmg.sh -v 1.2.0 -b 42     # 指定版本号与构建号
./Scripts/build-dmg.sh --notarize         # Developer ID 签名 + 公证（需证书与凭据）
```

流程：xcodebuild → 写版本号 → codesign → hdiutil 打包 → 校验并输出 SHA256。

签名档位由脚本自动选择：本机若有 `Developer ID Application` 证书就走正式签名
（hardened runtime + 时间戳，可公证）；否则退回 **ad-hoc**。工程里
`CODE_SIGNING_ALLOWED = NO` 是给日常开发用的，但 dmg 要分发——arm64 可执行文件
必须有签名，`.app` 外壳没有 bundle 签名则接收方 Gatekeeper 直接报「已损坏」，
所以这一步不能省。ad-hoc 档位下接收方首次打开需「右键 → 打开」。

产物落在 `build/dist/`（已被 `.gitignore` 忽略），日志在 `build/logs/`。

### 应用图标

源图 `App/Assets/AppIcon-source.jpg` 入库（git LFS 不需要，体量小）。**图标由 Xcode
构建阶段自动生成**（GameLobby target → `Generate AppIcon` →
`Scripts/make-appicon.sh`），与 `Copy WebRuntime` 同一机制：每次 Xcode ⌘R 或
xcodebuild 都跑，Debug / Release 都带图标。`build-dmg.sh` 不再生成图标，只做
产物校验。

脚本做的事：`sips` 把源图切成 10 个 PNG（16 / 16@2x / 32 / 32@2x / 128 / 128@2x /
256 / 256@2x / 512 / 512@2x），`iconutil` 合成 `AppIcon.icns` 后写到
`Contents/Resources/AppIcon.icns`。**换图标直接换源图**后重新编译即可，
下一次构建自动重新生成。

`Info.plist` 的 `CFBundleIconFile = AppIcon`（AppKit 约定，**不带** `.icns`
后缀）；codesign 时图标已经在 Resources 里，签名覆盖整个 Resources，所以图标
跟着签名。换图标也要重签（codesign 覆盖了 Resource 的内容摘要）。

#### 换了图标但 Finder / Dock 还显示旧的（甚至默认图标）

`AppIcon.icns` 明明在 bundle 里，系统却还按**旧的 LaunchServices 注册信息**取
图标——这是 macOS 的图标缓存，不是构建问题。先确认文件没问题：

```bash
# 1) 确认 icns 真在产物里且格式有效
file .../潮音之王.app/Contents/Resources/AppIcon.icns   # 期望: Mac OS X icon … "ic12" type
sips -g pixelWidth .../潮音之王.app/Contents/Resources/AppIcon.icns   # 期望: 1024

# 2) 重新向 LaunchServices 注册（这一步通常就够了，不重启任何进程）
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/\
LaunchServices.framework/Versions/Current/Support/lsregister -f -R .../潮音之王.app
```

上面两步行完若还不变，再重启承载图标的进程（会重开 Finder 窗口）：

```bash
killall Finder; killall Dock
```

排查时别被「bytes 数」误导：不同 app 的 `NSWorkspace.icon(forFile:)`
TIFF 常常**字节数完全相同**（representations 的尺寸集合是标准的），
要判有没有自定义图标得比 **md5**，不能比大小。

> ⚠️ 本工程刻意**不使用 SwiftPM**（含本地包）：本机环境 SwiftPM 的
> `sandbox_apply` 被系统拒绝（`sandbox-exec: sandbox_apply: Operation not permitted`），
> 任何含包的 xcodebuild 都无法完成解析。模块拓扑改用**五个 Swift 静态库 target**
> 实现，模块边界同样由编译器强制（import 关系 = target 依赖），后续若环境
> 修复可平移回 Package.swift（见下方拓扑对照）。

WebRuntime（引擎壳工程）由 `Copy WebRuntime` 构建阶段往主资源包写入，
实现是 `Scripts/copy-webruntime.sh`。它**只拷白名单文件**，路径与上一代一致：
入口链（`ios2-web-index.html` / `settings.b2e22.js` / `ios2-web-cocos2d.js` /
`ios2-web-boot.js` / `jsb-adapter/game-defines.js`）、`settings.jsList` 指向的
`HSDK.app.min.*.js`、`ScriptStore` 直接读盘的 `ios2-script-runtime.js`，
加上内置资源包 `assets/{internal,main}`。

`ios-cocos/cocos-project/src` 是 **iOS 原生 JSB 与 macOS WebRuntime 共用** 的目录。
`cocos2d-jsb.07adf.js`、`vendor/fairygui.js`、`ios2-login.js`、`ios2-manager*.js`、
`ios2-account-*.js`、`ios2-bin-page.js`、`ios2-config-page.js`、`ios2-script-page.js`
只服务原生 JSB 路径（由 `cocos-project/main.js` 的 require 链驱动），
进 macOS 包就是死重量（约 2.1 MB），因此被挡在白名单外。iOS 原生构建读的是
`cocos-project` 源目录，不受影响。

> 往 `src/` 里新增 `*.js` 时：`ios2-web-*.js` 会被自动纳入；其它名字若既不在白名单
> 也不在脚本末尾的「仅 iOS 原生」清单里，构建日志会打印 warning，请显式归类。

## 模块拓扑（规格 §3 的等价实现）

```
潮音之王.app（App target：装配根 + @main，唯一知道全部具体类型的地方）
 ├── LobbyUI      表现层：SwiftUI 大厅（毛玻璃六步配方 / 中控台侧栏 / 矩阵）+ 会话门面
 │                依赖 → Domain, Engine
 ├── LobbyEngine  引擎层：认证器 / 引导脚本 / HSDK 响应器 / 视口实例 / 实例池
 │                依赖 → Domain, IPC, Storage
 ├── LobbyStorage 存储层：账号 bin 库 / 设置镜像 / CDN 资产仓 / game-res 方案处理器
 │                依赖 → Domain
 ├── LobbyIPC     页面桥契约：PageEvent 强类型解码（阶段 2 追加 SecureXPC 契约）
 │                依赖 → Domain
 └── LobbyDomain  领域层：模型 / 协议 / 9:16 矩阵求解器 / 日志门面 / 全局配置（零依赖）
```

与规格 Package.swift 的对照：`LobbyDomain/Storage/Engine/IPC/UI` 五个 target
一一对应；`dependencies` 边一致；差异仅在实现载体（Xcode 静态库 vs SPM）。
依赖方向只允许自上而下，跨层直连会被编译器拒绝。

**依赖注入**：表现层只依赖领域协议（`AccountStoring` / `ResourceProviding` /
`GameAuthenticating`），具体实现全部在 `App/Sources/GameLobbyApp.swift` 的
`LobbyComposition` 装配根构造后注入——任何一层都可以独立替换 / mock。

## 目录结构

```
LobbyCoreSystem/
├── GameLobby.xcodeproj/       # 手写工程：6 个 target（App + 5 静态库）
├── App/
│   ├── Info.plist
│   └── Sources/GameLobbyApp.swift   # @main + 装配根 + App Nap 防护
├── Sources/
│   ├── LobbyDomain/           # 配置 / 账号模型 / MatrixFit 求解器 / 协议 / 日志
│   ├── LobbyIPC/              # PageEvent 强类型解码
│   ├── LobbyStorage/          # AccountBinStore / GameSettingsMirror / CDNAssetStore / SchemeHandler
│   ├── LobbyEngine/           # Authenticator / BootstrapScript / HSDKResponder / ViewportInstance / InstancePool
│   └── LobbyUI/               # Theme / SessionModel / RootView / 侧栏 / 矩阵
└── README.md
```

## 关键外部契约（页面侧硬编码，勿改）

| 常量 | 值 | 来源 |
|---|---|---|
| `LobbyConfiguration.webChannelName` | `ios2Game` | `webkit.messageHandlers.ios2Game` |
| `LobbyConfiguration.instanceGlobalName` | `__IOS2_GAME_INSTANCE__` | WebRuntime boot js |
| `LobbyConfiguration.gameURLScheme` | `ios2-game` | WebRuntime index.html script 标签 + boot.js 全链路硬编码（`settings.server = 'ios2-game://app/cdn'` 等）；规格书的 `game-res://` 与页面契约冲突，页面契约优先 |
| `LobbyConfiguration.identityPrefix` | `ios2-` | SDK 身份 = 前缀 + bin SHA256，保持与上一代一致避免游戏侧身份漂移 |

## 用户偏好（UserDefaults）

```
com.xyzw.gamelobby.macos
├── lobby.renderQuality          # low/medium/high（默认 high，改档需重启实例）
├── lobby.frameRate              # 15/24/30/45/60/90/120（白名单对齐 WebRuntime）
├── lobby.gameStorage.policy     # isolatedPerAccount / sharedAcrossAccounts / ephemeral
├── lobby.audio.muteWhenUnfocused# 默认 true
├── lobby.cdn.automaticCaching   # 默认 true
├── lobby.debug.webInspector     # 默认 false；开启后右键可调 Safari Web Inspector
└── lobby.log.level              # 0 verbose … 4 error（默认 2 info）
```

## 路线图

- **阶段 1（本版）**：大厅 + 账号库 + 登录 + 多开矩阵 + 能耗仲裁 + 共享 CDN
  + 分组管理 + 键鼠同步（群控）✅
- **阶段 2**：SecureXPC Helper 进程通信、全量资源预取（bundle config 展开）、
  渲染完整性自动重载的 HUD、矩阵拖拽换位的动画细化。
