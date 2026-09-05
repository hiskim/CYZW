# 游戏 App 架构

本文依据 Ardot 文件 `721098916642284`（`游戏App · UI 方案`）的 Page 1、S1-S26 及公共组件整理。它描述目标分层和运行时边界，不改变现有实现。设计稿中的“游戏窗口”是一个组合画面：窗口编排和原生控制栏属于 Shell，实际游戏内容由所选引擎实例承载。

## 1. 分层落点

### 层职责

| 层 | 责任 | 选择依据 |
| --- | --- | --- |
| L1 SwiftUI Shell | 账号、工作区、多选启动、插件、配置、状态栏、窗口布局和引擎控制 | 这些是本地产品能力，需要稳定的系统集成、可访问性和跨引擎一致性，不应随游戏资源热更新。 |
| L3-a WebKitInstance | 可热更新的 2D/页面型游戏内容：商城、背包、活动、游戏内设置 | 内容迭代快，使用独立 `WKWebView` 的数据仓、JS Realm 与资源缓存；适合设计稿的多开工作区。 |
| L3-b CocosNativeInstance | 3D 战斗、场景、HUD、血条、特效及高帧率交互 | 需要原生 GPU 渲染、压缩纹理解码和低延迟帧循环；不将其嵌入 WebKit。 |

### Frame 归属

| Frame / 组件 | 归属 | 依据 |
| --- | --- | --- |
| `CMP · 状态栏` | L1 | 系统级时间、网络、电量呈现，独立于游戏运行时。 |
| `S1 · 账号库（分组列表）` | L1 | 本地账号分组、搜索和账号选择；登录按钮只发起实例启动。 |
| `S2 · 登录中` | L1 | 采用 L1 SwiftUI 完整渲染登录页，包括账号凭据输入、认证状态、进度条、错误提示和取消按钮；凭据留在受保护的原生服务中，认证成功后才创建或启动 L3-a/L3-b 实例。 |
| `S3 · 游戏窗口（悬浮控制台）` | L1 + L3-a/L3-b | L1 负责窗口容器和暂停/快照/关闭控制；商城、背包、活动、游戏内设置进入 L3-a；3D 游戏画面、HUD、血条和特效进入 L3-b。 |
| `S4 · 游戏工具面板` | L1 | 是对当前 `EngineHost` 的暂停、恢复、快照和关闭等通用控制，不应耦合某个游戏页面。 |
| `S5 · UI 规范板` | L1（设计参考） | 令牌与共用控件规范，不作为引擎内容运行。 |
| `S6 · 多开 · 四宫格（方案1）` | L1 | 工作区布局，将多个实例快照或 live surface 编排为 2x2；不复制游戏逻辑。 |
| `S7 · 多开 · 主窗 + 子窗（方案2）` | L1 | 工作区主从布局和焦点管理；每个窗格仍绑定独立实例。 |
| `S8 · 窗口管理` | L1 | 运行实例的列表、状态和批量动作。 |
| `S9 · 退出指定窗口` | L1 | 对 `EngineHost.close()` 的确认流程。 |
| `CMP · 多开窗口 · 宫格`、`CMP · 窗口行` | L1 | 多开工作区的可复用展示组件。 |
| `Rectangle 1` | 资源层 | 480×275 的无命名 IMAGE 填充，当前组件树和画布均无法确认其业务用途；Round 5 导出时由用户确认，确认前不接入任何层或资源包。 |
| `S11 · 启动动效 · 星空月光` | L1 | App 启动和实例预热状态；不依赖游戏场景。 |
| `S12 · 首页 · 游戏已登录（后台保活）` | L1 | 首页、保活状态和启动入口；实际游戏会话在 EngineHost 内隔离。 |
| `S13 · 多开 · 灵动岛安全区适配` | L1 | iOS 安全区和窗口可见区域策略，必须由原生容器统一约束。 |
| `S14 · 插件管理 · JS 脚本`、`S15 · 导入插件 · JS 脚本`、`CMP · 插件行` | L1 | 插件安装、权限授予、启停和资源选择属于本地管理能力。 |
| `S16 · 扩展规范板 · 动效 / 安全区 / 插件` | L1（设计参考） | 对扩展能力的规则说明，不是可热更新的游戏页面。 |
| `S17 · 首页 · 横向分组 + 纵向列表` | L1 | S1 的账号库布局变体。 |
| `S18 · 快速选号 · 检索规范板` | L1 | 本地筛选、排序和账号选择规则。 |
| `S19 · 配置 · 主菜单`、`S20 · 显示设置`、`S21 · 游戏引擎模式`、`S22 · 系统与调试` | L1 | App/实例配置、引擎选择与调试开关需要稳定、受权限控制；游戏内设置另归 L3-a。 |
| `S23 · 多开工位（Tab 落点 · 有窗口）`、`S24 · 多开工位（空状态）` | L1 | 工作区 Tab 的有窗和空状态，负责创建、恢复、聚焦和编排实例。 |
| `S25 · 批量选号 · 多选启动` | L1 | 从本地账号库选择 N 个账号并批量创建 `EngineHost`。 |
| `S26 · 多开流程说明板` | L1（设计参考） | 描述 Shell 流程与交互规则，不是运行时游戏内容。 |

未在本设计稿中单列的商城、背包、活动、游戏内设置应统一落在 L3-a；未在设计稿中单列的 3D 战斗画面、HUD、血条和特效应统一落在 L3-b。登录及其认证 UI 例外，固定在 L1 SwiftUI，以便安全地保管凭据并控制取消、错误和重试状态。这样不会把需要热更新的内容固化进 SwiftUI，也不会让 WebKit 承担高性能 3D 渲染。

## 2. EngineHost 协议草案

`EngineHost` 是 L1 对两种运行时的唯一控制面。L1 只依赖协议，不直接调用 WebKit 或 Cocos 的私有 API。

```swift
import Foundation

protocol EngineHost: AnyObject {
    var id: UUID { get }
    var state: EngineState { get }

    func start(config: EngineConfig) async throws
    func pause() async
    func resume() async
    func snapshot() async throws -> Snapshot
    func inject(resource: ResourceRef) async throws
    func close() async

    var events: AsyncStream<EngineEvent> { get }
}

enum EngineKind: Sendable, Codable {
    case webKit
    case cocosNative
}

enum EngineState: Sendable, Equatable {
    case idle
    case starting
    case running
    case paused
    case updating(progress: Double)
    case failed(EngineFailure)
    case closed
}

struct EngineConfig: Sendable, Codable {
    let kind: EngineKind
    let account: AccountRef
    let launchTarget: LaunchTarget
    let resourcePolicy: ResourcePolicy
    let sandbox: SandboxPolicy
}

enum EngineEvent: Sendable {
    case stateChanged(EngineState)
    case progress(stage: EngineStage, fraction: Double)
    case navigationChanged(LaunchTarget)
    case resourceUpdated(ResourceRef)
    case memoryWarning
    case diagnostics(EngineDiagnostic)
    case terminated(reason: TerminationReason)
}

struct Snapshot: Sendable {
    let engineID: UUID
    let capturedAt: Date
    let image: ResourceRef
    let state: EngineState
}

struct ResourceRef: Sendable, Codable, Hashable {
    let identifier: String
    let revision: String
    let location: ResourceLocation
    let integrity: String?
    let scope: ResourceScope
}
```

关联类型及约束如下：

| 类型 | 关联关系 |
| --- | --- |
| `EngineState` | `EngineHost.state` 的可观察生命周期。仅 `running` 和 `paused` 实例可提供稳定快照；`closed` 后不能重启同一对象。 |
| `EngineConfig` | `start(config:)` 的输入。`kind` 决定创建 `WebKitInstance` 或 `CocosNativeInstance`；`account`、资源策略和沙箱随实例固定。 |
| `EngineEvent` | `events` 的单向事件流。它报告状态、热更新、导航、诊断和终止，不作为插件反向修改协议状态的通道。 |
| `Snapshot` | `snapshot()` 的输出，记录来源 `engineID`、捕获时间、实例状态和只读图像 `ResourceRef`，供 L1 工作区缩略图使用。 |
| `ResourceRef` | `inject(resource:)`、热更新和 `Snapshot.image` 的统一引用。必须带版本和可选完整性校验，不能是任意文件路径或未验证 URL。 |
| 支撑类型 | `AccountRef` 仅持有账户记录 ID；`LaunchTarget` 区分登录、商城、背包、活动、游戏内设置、3D 战斗等目标；`ResourcePolicy` 限制可接受的签名资源；`SandboxPolicy` 规定数据仓、网络白名单和文件访问范围。 |

状态转换应为 `idle -> starting -> running <-> paused -> closed`。资源热更新期间可进入 `updating` 后回到 `running` 或 `paused`；失败进入 `failed`，并以终止事件说明原因。`pause`、`resume`、`close` 需设计为幂等，以支持 L1 批量操作与应用前后台切换。

## 3. 多实例工作区模型

L1 的 `WorkspaceStore` 持有 `WorkspaceItem` 列表，每项以稳定的 `EngineHost.id` 作为身份，而不是以画布位置或账号昵称作为身份。S23 是有实例时的工作区，S24 是空状态；S6/S7 是同一模型的两种布局投影。

| 范畴 | 设计 |
| --- | --- |
| 标签页布局 | 每个实例对应一个可选中标签。标签页保留 `id`、账号显示信息、`EngineState` 与最近 `Snapshot`；切换焦点不销毁后台实例。S6 使用四宫格，S7 使用主窗加子窗，布局只变更 L1 呈现。 |
| 创建和批量启动 | S25 生成选中账号集合，L1 为每个账号创建一个 `EngineHost`，按配置的顺序和间隔调用 `start`；S8 汇总状态并提供批量暂停、恢复、关闭。 |
| 实例隔离 | 每个 WebKit 实例使用独立 `WKWebsiteDataStore`、Cookie、LocalStorage、JS Realm、下载目录和会话令牌。每个 Cocos 实例必须有独立 scene/runtime 上下文、资源缓存命名空间和渲染 surface，不能共享可变的全局游戏状态。 |
| 沙箱策略 | 账户凭据保留在 Keychain 或受保护的 L1 服务中，实例仅取得短生命周期授权。实例文件访问被限制在自己的容器和受签名的资源缓存；网络仅允许认证、资源 CDN 和明确配置的游戏域名。实例之间不共享 Cookie、脚本上下文、临时文件或消息通道。 |
| 生命周期与资源 | 后台实例优先 `pause` 并只保留快照；内存警告按最近未聚焦顺序暂停或关闭。L1 不从实例内读写任意文件，只接收 `events` 并请求 `snapshot()`。 |

当前仓库的 Cocos 路径在 README 中明确为单实例；因此目标协议可表示 N 个 `EngineHost`，但首期策略应限制 `CocosNativeInstance` 最大并发数为 `1`。S6/S7 的 2-4 窗格多开由 `WebKitInstance` 承担，直到 Cocos 的全局运行时、GPU surface 和资源缓存完成真正的实例化隔离后，才可以提高 Cocos 并发上限。

## 4. 插件边界

插件由 L1 的 `PluginManager` 管理并在沙箱中运行。插件面板对应 S14/S15，插件行对应 `CMP · 插件行`；它们不能被直接加载进宿主进程的任意地址空间或任意游戏 JS Realm。

| 允许扩展点 | 规则 |
| --- | --- |
| 事件订阅 | 可订阅经过权限过滤的 `EngineEvent`，例如状态变化、资源更新、诊断和实例终止；订阅为只读且可撤销。 |
| 资源注入 | 可请求将经签名、校验版本与完整性的 `ResourceRef` 注入指定实例。实际 `inject(resource:)` 仍由 L1 审批并执行。 |
| UI 注入 | 仅可通过 L1 注册受限的 SwiftUI 面板、命令或设置项，并声明展示位置与所需权限；UI 不能覆盖系统安全提示、账号凭据页面或游戏渲染 surface。 |

禁止的扩展包括：

- 不允许重写、替换或 hook `EngineHost` 的核心方法，也不能伪造 `EngineState`、`Snapshot` 或 `EngineEvent`。
- 不允许创建未注册的引擎实例、绕过工作区并发上限，或访问其他实例的数据仓、Cookie、令牌与缓存。
- 不允许读取 Keychain、任意本地文件、剪贴板或未授权网络域名；资源只能经 `ResourceRef` 和 L1 审核通道进入实例。
- 不允许注入游戏的 3D 渲染循环、Cocos 场景图或 WebKit 私有脚本上下文。游戏内容更新走受签名的资源包与既有更新机制，而不是插件直接篡改运行时。

插件权限应在安装或首次启用时显式授予，按插件 ID 和目标实例记录；关闭插件或撤销授权时，L1 取消订阅、移除 UI 扩展并拒绝后续资源注入。

## 5. Token 决策

本节依据 Ardot 文件 `721098916642284` 的本地变量集 `启动器令牌`（唯一模式：`深色`）制定实现契约。L1 SwiftUI 与 WebKit Shell 应消费同一组语义 token；游戏引擎内部的热更新资源不得反向定义 Shell token。

### 颜色、间距与圆角

以下 12 个颜色、4 个间距和 4 个圆角 token 直接保留原始变量名、值与语义，不重新命名为视觉色阶。CSS 使用 `--color-*`、`--space-*`、`--radius-*` 映射；SwiftUI 使用同名的语义常量。

| 类别 | Token | 值 | 用途决策 |
| --- | --- | --- | --- |
| 颜色 | `画布` | `#000000` | App 与工作区根背景。 |
| 颜色 | `卡片` | `#1C1C1F` | 标准账号卡、列表卡和工具卡。 |
| 颜色 | `卡片高` | `#29292B` | 悬浮、选中或更高层级的卡片。 |
| 颜色 | `面板` | `#262626` | 抽屉、工具面板和局部容器。 |
| 颜色 | `描边` | `#3B3B3D` | 低强调边界、分隔线和控件描边。 |
| 颜色 | `强调` | `#2996FF` | 选中态、链接、进度与非破坏性强调操作。 |
| 颜色 | `主按钮` | `#0066CC` | 主 CTA 的实体填充。 |
| 颜色 | `文字主` | `#FFFFFF` | 标题、正文和高优先级标签。 |
| 颜色 | `文字次` | `#8F8F94` | 辅助说明、次级元数据与占位文案。 |
| 颜色 | `文字弱` | `#6E6E73` | 禁用、低优先级或不抢占注意力的文案。 |
| 颜色 | `成功` | `#30D159` | 已登录、运行正常和成功反馈。 |
| 颜色 | `危险` | `#FF453B` | 关闭、删除、错误与不可逆动作。 |
| 间距 | `sm` | `8` | 图标与文案、紧凑控件内部间距。 |
| 间距 | `md` | `12` | 常规卡片内容、列表项与相关控件组。 |
| 间距 | `lg` | `16` | 卡片内边距、小节内部和标准行距。 |
| 间距 | `xl` | `20` | 页面边距与主要小节间距。 |
| 圆角 | `卡片` | `18` | 标准内容卡和工作区卡片。 |
| 圆角 | `控件` | `12` | 输入框、工具按钮和一般容器。 |
| 圆角 | `图标` | `14` | 图标底座和游戏图标。 |
| 圆角 | `胶囊` | `9999` | 筛选标签、状态标签和圆形/胶囊按钮。 |

### 字号

决策：新增字号 token。Ardot 目前在画板中硬编码 `11/12/13/14/15/22px`，持续硬编码会使 SwiftUI 与 WebKit Shell 的文本层级漂移。新增 token 只封装现有值，不引入新字号。

| Token | 值 | UI 场景 |
| --- | --- | --- |
| `xs` | `11px` | 画布引用、极弱辅助信息和紧凑状态说明。 |
| `sm` | `12px` | 标签、次要动作、辅助文案、分组数量与元数据。 |
| `md` | `13px` | 常规次级正文、筛选标签和列表辅助信息。 |
| `lg` | `14px` | 正文、表单输入、主要按钮与标准列表标题。 |
| `xl` | `15px` | 小标题、卡片标题、工具面板段落标题。 |
| `xxl` | `22px` | 页面大标题，例如账号库标题。 |

### 深浅色扩展位

决策：在 `design-tokens.css` 预留 `[data-theme="light"]` 扩展位，但本期值与深色 token 完全相同，且不提供主题切换入口或跟随系统逻辑。这建立稳定的选择器与变量覆盖契约，未来有正式浅色设计稿时只替换该覆盖层的值；本期视觉仍严格保持 Ardot 的唯一“深色”模式。

`Rectangle 1`（节点 `5:1`）的决定维持为“Round 5 导出时由用户确认”。该节点仅能确认是 480×275 的 IMAGE 填充，无法从节点名、层级或相邻画板得出可靠用途，因此不得编造加载归属。

## 7. 实现状态

| 分层 | 状态 | 实现位置 | 备注 |
| --- | --- | --- | --- |
| L1 SwiftUI Shell | 已实现 | `ios/Shell/` | 账号库、工作区、插件面板和设置均消费 `DesignTokens.shared`。 |
| L2 EngineHost | 已实现 | `ios/EngineHost/` | 维持本文定义的 `EngineHost` 控制面；`EngineHostError.notMultiInstanceSupported` 用于 Cocos 单实例策略。 |
| L3-a WebKitInstance | 已实现 | `ios/WebKitInstance/`、`h5-ui/` | 每个实例有独立配置和非持久化数据仓；H5 契约见 `shared/BRIDGE.md`。 |
| L3-b CocosNativeInstance | 已实现为原生桥接层 | `ios/CocosInstance/` | 单实例，调用 Cocos Director/JSB 适配器。当前仓库的 Creator 2.4.9 运行时实际提供 `CCEAGLView`；未来 Metal `CCView` 可通过同一桥接接口接入。 |
| L3-b 设计资产 | 等待设计输入 | `cocos-assets/` | Ardot 中没有 L3-b 的具名 Frame；没有将 L1 启动动效或工作区资源错误导出给 Cocos。 |
| 插件边界 | 已实现 | `ios/Plugins/` | 插件只能通过沙箱订阅事件、申请资源注入或返回受限 UI 注入。 |

## 6. EngineHostRegistry

`WorkspaceStore` 只保存工作区顺序、当前焦点和布局偏好；`EngineHostRegistry` 是进程内唯一的活跃实例索引。注册、反注册和并发校验必须经过该注册中心，避免 S8、S23、S24、S25 各自维护相互矛盾的实例集合。

```swift
import Foundation

private protocol RegistryBackedEngineHost: EngineHost {
    var account: AccountRef { get }
    var kind: EngineKind { get }
}

final class EngineHostRegistry {
    static let shared = EngineHostRegistry()

    private var hosts: [UUID: EngineHost] = [:]
    private var byAccount: [String: UUID] = [:]

    private init() {}

    func register(_ host: EngineHost) {
        guard let registeredHost = host as? RegistryBackedEngineHost else {
            preconditionFailure("EngineHost must expose registry metadata")
        }

        if let existingID = byAccount[registeredHost.account.id] {
            precondition(existingID == host.id, "Account already has an active EngineHost")
        }

        hosts[host.id] = host
        byAccount[registeredHost.account.id] = host.id
    }

    func unregister(id: UUID) {
        guard let host = hosts.removeValue(forKey: id) else { return }
        if let registeredHost = host as? RegistryBackedEngineHost,
           byAccount[registeredHost.account.id] == id {
            byAccount.removeValue(forKey: registeredHost.account.id)
        }
    }

    func host(for id: UUID) -> EngineHost? {
        hosts[id]
    }

    func host(forAccount account: AccountRef) -> EngineHost? {
        guard let id = byAccount[account.id] else { return nil }
        return hosts[id]
    }

    func allHosts() -> [EngineHost] {
        Array(hosts.values)
    }

    func hosts(ofKind kind: EngineKind) -> [EngineHost] {
        hosts.values.filter { ($0 as? RegistryBackedEngineHost)?.kind == kind }
    }

    func canCreate(kind: EngineKind) -> Bool {
        hosts(ofKind: kind).count < concurrencyLimit(for: kind)
    }

    private func concurrencyLimit(for kind: EngineKind) -> Int {
        switch kind {
        case .webKit:
            return 4
        case .cocosNative:
            return 1
        }
    }
}
```

`AccountRef.id` 是账户记录的稳定字符串 ID。一个账户在同一时刻只允许注册一个活跃宿主；要替换同账户实例，必须先完成旧实例的 `close()` 和 `unregister(id:)`，注册中心不会静默丢弃仍在运行的宿主。`EngineHostFactory` 是唯一允许构造 `RegistryBackedEngineHost` 的入口，并在 `canCreate(kind:)` 通过后创建和注册实例。`unregister(id:)` 必须在 `close()` 完成或收到终止事件后调用，不能因工作区标签被隐藏而提前调用。
