import SwiftUI
import LobbyDomain
import LobbyEngine

/// 大厅根视图：左侧中控台侧栏（账号 / 脚本 / 设置）+ 右侧恒定的多开矩阵。
///
/// 分层（自底向上）：
/// -1 真实毛玻璃（behindWindow 折射桌面壁纸）
///  0 氛围光（深蓝底 + 径向色斑 + 星场 / 光束）
///  1 玻璃面板层（侧栏）
///  2 内容层（侧栏内容 + 矩阵画布）
public struct LobbyRootView: View {
    @ObservedObject public var session: LobbySessionModel

    /// 构建指纹，当作版本号显示在窗口左下角。
    /// **由装配根注入**——LobbyUI 不能反向依赖 App target，所以不能直接读
    /// `LobbyComposition.buildTag`。
    public let buildTag: String

    @State private var selectedSection: SidebarSection = .accounts
    @State private var sidebarVisible = true

    /// 侧栏固定宽度。玻璃面板宽、内容层列宽、顶部拖拽条宽度必须同源。
    private static let sidebarWidth: CGFloat = 304
    /// hiddenTitleBar 顶部拖拽条高度。
    private static let topDragHeight: CGFloat = 28
    /// 红黄绿交通灯那一带的宽度（实测约 78pt，留余量取 96）。
    private static let trafficLightsClearance: CGFloat = 96

    public init(session: LobbySessionModel, buildTag: String) {
        self.session = session
        self.buildTag = buildTag
    }

    public enum SidebarSection: String, CaseIterable, Identifiable {
        case accounts, scripts, settings
        public var id: String { rawValue }

        var title: String {
            switch self {
            case .accounts: return "账号"
            case .scripts: return "脚本"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .accounts: return "person.2"
            case .scripts: return "puzzlepiece.extension"
            case .settings: return "gearshape"
            }
        }
    }

    public var body: some View {
        ZStack {
            // ── 第 -1 层 · 真实毛玻璃：behindWindow 直接折射桌面壁纸。
            LobbyVibrancyBackdrop()
                .ignoresSafeArea()

            // ── 第 0 层 · 底层氛围光。没有这层，玻璃透出来的永远是同一块纯色。
            LobbyAmbientGlowBackground()
                .ignoresSafeArea()

            // ── 第 1 层 · 玻璃面板层（侧栏背景）。
            // 关键：HStack 里只有侧栏一个孩子时，它会被 ZStack 默认居中——
            // 304pt 的玻璃面板会「飞」到窗口中央变成一块灰板。
            // 必须显式靠左铺满，让玻璃垫回侧栏正下方。
            HStack(spacing: 0) {
                if sidebarVisible {
                    ZStack {
                        LobbyVibrancyBackdrop(material: .sidebar)
                        Color.black.opacity(0.34)
                        LobbyRefractionTint()
                        Rectangle().fill(Color.white.opacity(0.05))
                    }
                    .frame(width: Self.sidebarWidth)
                    // 04 右缘 1px 描边（上亮下暗）——玻璃的「厚度感」。
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.07)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 1)
                    }
                    // 06 外投影：把侧栏从大厅上「抬起」。
                    .shadow(color: .black.opacity(0.40), radius: 22, x: 6, y: 0)
                    .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea()
            // 05 窗口顶边 1px 内高光：整块玻璃的「顶面」。
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }

            // ── 第 2 层 · 内容层：列宽与背景层一一对应。
            // 「脚本」「设置」分节与「账号」同构：管理界面在侧栏内，
            // 右侧工作区始终是多开矩阵。
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: Self.sidebarWidth)
                    Color.clear.frame(width: 1)
                }
                MatrixStageView(session: session, sidebarVisible: $sidebarVisible)
            }
        }
        .overlay(alignment: .topLeading) {
            // hiddenTitleBar 顶部拖拽兜底。⚠️ 条带内的 mouseDown 会被 AppKit
            // 消费成拖窗口（点击黑洞），必须避开所有交互控件：
            // · 侧栏可见 → 只铺侧栏这一列（侧栏标题有 36pt 顶部留白，条带内无控件）；
            // · 侧栏隐藏 → 只铺交通灯那一带，工作区控制条从它右边开始。
            // 两态顶部高度一致，不加纵向留白（纵向留白直接扣游戏画面高度）。
            if sidebarVisible {
                LobbyTitleBarDragRegion()
                    .frame(width: Self.sidebarWidth, height: Self.topDragHeight)
            } else {
                LobbyTitleBarDragRegion()
                    .frame(width: Self.trafficLightsClearance, height: Self.topDragHeight)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = session.statusMessage {
                statusToast(message)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // 版本号（构建指纹）。纯装饰，必须 allowsHitTesting(false)：
            // 左下角看着是空白（侧栏底部有 Spacer），但侧栏可隐藏，那时这块
            // 就压在矩阵画面上——不能让它吃掉任何点击。
            Text("v\(buildTag)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.34))
                .padding(.leading, 14)
                .padding(.bottom, 9)
                .allowsHitTesting(false)
        }
        .task {
            session.refresh()
            // 启动后补拉「还没有资料」的账号：不启动游戏，直接用 .bin 凭据问服务端。
            // 延迟几秒再开始——别跟窗口首帧、CDN 预热抢带宽；运行中的账号会被自动跳过。
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            session.autoRefreshMissingProfiles()
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部标题（36pt 顶部留白 = 交通灯 + 拖拽条的呼吸区，条带内无控件）。
            // 刻意保留「游戏大厅」：这是侧栏功能区标题，不跟随 app 显示名改动。
            Text("游戏大厅")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 36)

            SidebarSectionSwitcher(selection: $selectedSection)

            switch selectedSection {
            case .accounts:
                AccountSidebarView(session: session)
            case .scripts:
                ScriptSidebarView(session: session)
            case .settings:
                SidebarSettingsView(session: session)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func statusToast(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.72)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .padding(.bottom, 14)
            .task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                session.statusMessage = nil
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - 分节切换条

/// 三个分节切换按钮（身份稳定 + 显式命中区域 + AppKit 悬停层，
/// 点击可靠性修复三件套——见 LobbyHoverHighlightModifier 注释）。
struct SidebarSectionSwitcher: View {
    @Binding var selection: LobbyRootView.SidebarSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LobbyRootView.SidebarSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: section.icon).font(.system(size: 14, weight: .semibold))
                        Text(section.title).font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(selection == section ? .white : .secondary)
                    .background(selection == section ? Color.cyan.opacity(0.2) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    // 显式命中形状：圆角矩形整面可点，语义与视觉边界一致。
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .lobbyHoverHighlight(cornerRadius: 7, intensity: 0.08)
                .help("切换到\(section.title)分节")
            }
        }
    }
}

// MARK: - 分节占位（阶段 2 功能）

struct SidebarPlaceholderView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .lobbyGlassCard(cornerRadius: 12, fillOpacity: 0.04, material: nil)
        .padding(.top, 4)
    }
}
