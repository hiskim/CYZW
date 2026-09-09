---
name: macos-cdn-cache
description: 维护 IOS2 macOS WebKit 游戏的共享 CDN 资源缓存、预下载策略、缓存诊断和资源一致性验证，适用于处理 PVR/BIN 下载、缓存命中、404 重试、白屏或多账号共用资源问题。
---

# macOS CDN 缓存

## 目标

让 macOS WebKit 游戏的 CDN 文件在所有游戏窗口和账号之间共享，同时保持账号 Cookie、Local Storage 和 WebKit 页面状态隔离。启动预缓存不能阻塞账号认证或游戏首屏；关闭自动预缓存时，资源由游戏进入后的按需请求写入同一份缓存。

## 核心约束

1. 共享缓存由 `MacCDNResourceManager` actor 管理，缓存目录是 `~/Library/Application Support/IOS2/CDN`，实际文件位于 `files/`，URL 到文件的映射位于 `index.json`。
2. 资源缓存键必须是完整 HTTPS URL（包括 bundle、版本、路径、扩展名和查询参数）。不同 URL 不得因为文件名相似而互相覆盖。
3. 所有账号和窗口必须复用 `MacCDNResourceManager.shared.data(for:)`；不要在单个 WebView、账号目录或 Cookie 存储中复制游戏资源。
4. `prepareForLaunch()` 只能等待 manifest 和核心入口文件（通常是 `launcher`、`game`、`TEST_REMOTE_MODULE`、`main` 的 config/index）；PVR/BIN 全量预下载必须后台执行，不能阻塞认证和 `webView.load`。
5. 总开关关闭时，不启动自动预缓存；游戏通过 `MacGameSchemeHandler` 的按需请求仍可写入共享缓存。
6. 空闲模式开启时，只允许在没有活动账号会话时预缓存；账号认证成功后暂停后台预缓存，所有窗口关闭后才恢复。
7. 404 资源需要负缓存或等效抑制机制，避免每次启动、同步或页面访问重复请求明确不存在的 URL。负缓存必须有过期时间，以便 CDN 后续发布资源后重新检测。
8. 不要把预下载日志中的 `CDN request` 当作网络下载证据。它只表示 WebKit 请求了资源；是否联网必须看 `network download started/completed` 或 `served from shared cache`。
9. 预下载 URL 必须从 manifest、bundle config 的 `uuids`、`paths`、`versions`、`importBase` 和 `nativeBase` 推导。不要凭文件名猜测未知扩展名；若确实需要候选扩展，应限制范围并记录 404。
10. 缓存清理会影响所有账号和窗口。执行前确认这是用户明确要求的共享缓存操作，并同步取消正在运行的下载任务。

## 优先排查位置

先使用以下搜索定位缓存链路：

```sh
rg -n "MacCDNResourceManager|prepareForLaunch|prefetchAllResources|synchronizeCache|clearCache|MacGameSchemeHandler|served from shared cache|network download|missing URL" ios/Shell
```

重点文件：

- `ios/Shell/MacCDNResourceManager.swift`：manifest 获取、URL 生成、共享缓存、并发下载、404 负缓存、自动/空闲策略和缓存状态。
- `ios/Shell/MacWebKitGameWindow.swift`：`ios2-game://` 到 HTTPS CDN 的映射、游戏按需资源请求、登录会话开始/结束和 WebKit 加载日志。
- `ios/Shell/SettingsView.swift`：自动缓存总开关、空闲缓存开关、同步/清理/打开目录按钮及缓存状态显示。
- `ios/Shell/MainApp.swift`：应用启动时触发的 launch preparation；不得在这里等待全量资源。
- `ios-cocos/cocos-project/src/ios2-web-boot.js`：游戏侧 Cocos 资源加载、PVR/BIN 请求和启动下载跟踪日志。

## 诊断与一致性证明

对同一个资源，按以下顺序核对：

1. `MacGameSchemeHandler` 打印的 `ios2-game://` 路径是否映射为预下载使用的同一 HTTPS URL。
2. 游戏请求后，管理器是否输出 `game served from shared cache`。这表示直接读取 `files/`，没有网络下载。
3. 若输出 `game network download started`，说明该 URL 尚未缓存、缓存失效或被清理；下载完成后应出现 `network download completed and cached`。
4. 比较日志中的 URL、字节数、SHA-256 和缓存文件名。URL 相同且 SHA-256 相同，即可证明游戏使用了自动预缓存的同一份字节内容。
5. 设置页显示的文件数和占用空间只能证明缓存规模，不能单独证明某个游戏资源已命中。

典型命中证据：

```text
CDN request: ios2-game://app/<bundle>/native/.../<uuid>.<version>.pvr
game served from shared cache: https://.../remote/<bundle>/native/.../<uuid>.<version>.pvr (... bytes, sha256=..., file=...)
```

## 修改原则

1. 先区分三种请求来源：`prefetch`（启动/空闲预缓存）、`sync`（设置页手动同步）和 `game`（WebKit 游戏按需加载），再修改并发、日志或策略。
2. 修改缓存策略时保持以下状态转换：启动准备 -> 可认证/可加载 -> 后台预缓存；认证成功 -> 活动会话计数增加并按策略暂停空闲预缓存；最后一个窗口关闭 -> 空闲预缓存恢复。
3. 不要让手动“同步缓存”误用启动路径的非阻塞语义。手动同步可以等待完整任务，但必须显示忙碌状态并允许清理操作取消后台下载。
4. 遇到大量 404，先检查 bundle config 的真实资源类型和 CDN 路径，再调整扩展名推导；不要简单无限重试或通过删除缓存掩盖错误。
5. 不要为每个账号建立独立 CDN 目录。账号隔离只适用于认证响应、Cookie 和 WebKit 数据存储。
6. 处理白屏时优先确认认证和 `webView.load` 没有等待全量预下载，并保留可见的加载/错误状态和关键日志。

## 验证

静态检查：

```sh
git diff --check
python3 /Users/gg/.codex/skills/.system/skill-creator/scripts/quick_validate.py .github/skills/macos-cdn-cache
```

macOS 构建：

```sh
xcodebuild -project ios/Shell/IOS2-Mac.xcodeproj \
  -scheme IOS2-Mac -configuration Debug -sdk macosx \
  -derivedDataPath /tmp/ios2-macos-derived \
  CODE_SIGNING_ALLOWED=NO build
```

运行验证至少覆盖：

- 清理缓存后启动：核心资源可准备，登录窗口不白屏，全量任务在后台推进。
- 自动缓存总开关关闭：启动不出现预下载任务；进入游戏后首次请求可以写入缓存。
- 空闲模式开启：无账号时预缓存，登录账号后暂停，关闭最后一个账号窗口后恢复。
- 同一资源先由预缓存下载，再进入游戏，日志显示 `game served from shared cache`，URL/字节数/SHA-256 一致。
- 404 URL 在负缓存有效期内不会反复联网请求；缓存清理后可重新开始。
- 两个以上账号或应用实例同时加载同一资源时只产生一次共享下载，其余请求等待或命中缓存。
