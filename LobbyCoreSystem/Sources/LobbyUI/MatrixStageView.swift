import SwiftUI
import LobbyDomain
import LobbyEngine

/// 矩阵卡片布局帧上报（拖拽换位的命中测试输入）。
struct MatrixCardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 多开矩阵舞台：画布测量 → 求解器算尺寸 → 网格摆卡片 + 群控状态胶囊。
///
/// 数据源红线：适配计数与 ForEach 渲染必须共用 `session.matrixAccounts`——
/// 任何一边多算 / 漏算，卡片尺寸都会错。
struct MatrixStageView: View {
    @ObservedObject var session: LobbySessionModel
    /// 群控中控：状态胶囊（主控驱动 / 互相同步 / idle）直接观察它。
    @ObservedObject private var sync: InputSyncController
    /// 侧栏显隐（由根视图持有，顶栏开关读写）。
    @Binding var sidebarVisible: Bool
    /// 画布可视区尺寸（自动适配的输入；首帧为 0，随后立即被真实尺寸覆盖）。
    @State private var canvasViewport: CGSize = .zero
    /// 尺寸模式：true = 自动适配（跟随画布、严格 9:16、单实例优先吃满高度）；
    /// false = 手动（用 ± 调过的宽度，点 ± 以当前实际宽度为起点自动切手动）。
    @AppStorage("lobby.matrix.autoSize") private var isAutoSizing = true
    /// 手动模式下的卡片宽度（持久化；± 步进 ±20）。
    @AppStorage("lobby.matrix.instanceWidth") private var instanceWidth: Double = 280
    /// 每行显示的窗口数（nil = 自动按宽度适配；1~12 手动固定）。
    @State private var fixedColumns: Int?

    /// 各卡片的实时布局帧（全局坐标，拖拽命中测试输入）。
    @State private var cardFrames: [String: CGRect] = [:]
    /// 拖拽开始那一刻的布局快照：拖动过程中卡片会带动画换位，
    /// 命中测试始终用**快照**（起点布局），否则动画中的帧会使命中抖动。
    @State private var dragSnapshot: [String: CGRect]?

    /// 红黄绿交通灯避让带宽度（与 LobbyRootView 的同名常量保持一致）。
    /// 侧栏隐藏时控制条必须从这里之后开始，否则开关 chip 落进顶部拖拽区，
    /// 点击会被 AppKit 消费成拖窗口（点击黑洞）。
    private static let trafficLightsClearance: CGFloat = 96

    init(session: LobbySessionModel, sidebarVisible: Binding<Bool>) {
        self.session = session
        _sync = ObservedObject(wrappedValue: session.sync)
        _sidebarVisible = sidebarVisible
    }

    /// 当前矩阵布局：自动适配 / 手动尺寸统一输出同一份 MatrixLayout，
    /// 两种模式共用网格与卡片渲染代码（body 与尺寸控制条共用）。
    private var currentLayout: MatrixLayout {
        isAutoSizing
            ? MatrixFit.fit(count: session.matrixAccounts.count,
                            in: MatrixCanvasMetrics.contentSize(from: canvasViewport),
                            forcedColumns: fixedColumns)
            : MatrixFit.manual(count: session.matrixAccounts.count,
                               preferredWidth: CGFloat(instanceWidth),
                               in: MatrixCanvasMetrics.contentSize(from: canvasViewport),
                               forcedColumns: fixedColumns)
    }

    var body: some View {
        let entries = session.matrixAccounts
        let layout = currentLayout
        // 控制条是**固定顶栏**而非悬浮层：窗口再小也不会压住第一行卡片的标题
        // （悬浮 overlay 在单实例吃满画布时与卡片标题重叠——实测截图）。
        VStack(spacing: 0) {
            controlBar
            ZStack {
                canvas(entries: entries, layout: layout)
                if entries.isEmpty {
                    emptyState
                }
            }
            // 画布可视区只测量控制条以下的区域（自动适配的输入）。
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { canvasViewport = proxy.size }
                        .onChange(of: proxy.size) { _, newSize in
                            canvasViewport = newSize
                        }
                }
            )
        }
        .onPreferenceChange(MatrixCardFramesKey.self) { frames in
            cardFrames.merge(frames) { _, new in new }
        }
        .confirmationDialog(
            "删除分组「\(session.groupDeletionCandidate?.groupName ?? "")」",
            isPresented: Binding(
                get: { session.groupDeletionCandidate != nil },
                set: { if !$0 { session.groupDeletionCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除分组并删除组内账号文件", role: .destructive) {
                session.deleteGroupMembers = true
                if let group = session.groupDeletionCandidate {
                    session.deleteGroup(id: group.id, deletingMembers: true)
                }
                session.groupDeletionCandidate = nil
            }
            Button("仅删除分组（成员移入未分组）", role: .destructive) {
                if let group = session.groupDeletionCandidate {
                    session.deleteGroup(id: group.id, deletingMembers: false)
                }
                session.groupDeletionCandidate = nil
            }
            Button("取消", role: .cancel) { session.groupDeletionCandidate = nil }
        } message: {
            Text("删除分组并删除成员会永久删除组内全部账号的凭据文件，且不可恢复。")
        }
    }

    // MARK: - 矩阵顶栏控制条

    /// 固定顶栏：左侧 = 侧栏开关 + 群控 chips；右侧 = 尺寸控制 + 每行列数 +
    /// 一键关闭。固定高度、不随卡片滚动、永不与卡片标题重叠。
    private var controlBar: some View {
        HStack(spacing: 6) {
            sidebarToggleChip
            syncActionChip
            syncStatusChip
            Spacer(minLength: 8)
            sizeControlChip
            columnsMenu
            closeAllChip
        }
        // 侧栏隐藏时左移让出交通灯带（96 + 8 间距）——避让方向选横向，
        // 不下移控制条（两态顶部高度保持一致）。
        .padding(.leading, sidebarVisible ? 8 : Self.trafficLightsClearance + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            Color.black.opacity(0.28)
        )
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
    }

    // MARK: - 标题栏拖拽换位

    /// 拖动经过某张卡片（用**起点布局快照**做命中测试）就把拖拽卡换到它前面。
    private func headerDrag(_ value: DragGesture.Value) {
        let location = value.location
        if dragSnapshot == nil {
            dragSnapshot = cardFrames
            if let startID = cardFrames.first(where: { $0.value.contains(location) })?.key {
                session.draggingMatrixAccountID = startID
            }
        }
        guard let draggingID = session.draggingMatrixAccountID,
              let snapshot = dragSnapshot else { return }
        guard let targetID = snapshot.first(where: { $0.value.contains(location) })?.key,
              targetID != draggingID else { return }
        session.moveMatrixAccount(draggingID, before: targetID)
    }

    private func headerDragEnded() {
        session.draggingMatrixAccountID = nil
        dragSnapshot = nil
    }

    // MARK: - 群控控制条（一键同步 chip + 分组感知状态 chip，对齐旧版语义）

    /// 当前运行实例的 ID 集合（矩阵与群控共用同一份运行实例数据源）。
    private var liveSyncAccountIDs: [String] {
        session.runningAccountIDs
    }

    private var allLiveInstancesAreSyncing: Bool {
        !liveSyncAccountIDs.isEmpty && liveSyncAccountIDs.allSatisfy { sync.isReceiver($0) }
    }

    /// 侧栏显隐开关：隐藏后画布铺满整窗（顶部拖拽区自适应已就位）。
    @ViewBuilder
    private var sidebarToggleChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(sidebarVisible ? Color.white.opacity(0.85) : Color.cyan)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous)
                    .fill(sidebarVisible ? Color.white.opacity(0.08) : Color.cyan.opacity(0.16)))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(sidebarVisible ? Color.white.opacity(0.16) : Color.cyan.opacity(0.55), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
        .help(sidebarVisible ? "隐藏左侧边栏" : "显示左侧边栏")
    }

    /// 一键关闭全部运行中的账号（逐个走账号级关闭：群控退休 + 池销毁）。
    @ViewBuilder
    private var closeAllChip: some View {
        if !liveSyncAccountIDs.isEmpty {
            Button {
                session.closeAll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10, weight: .bold))
                    Text("关闭全部（\(liveSyncAccountIDs.count)）")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.42))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous)
                    .fill(Color(red: 1.0, green: 0.45, blue: 0.42).opacity(0.14)))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Color(red: 1.0, green: 0.45, blue: 0.42).opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
            .help("一键关闭全部运行中的实例")
        }
    }

    // MARK: - 尺寸控制（自动适配 / 手动 ± / 每行窗口数）

    /// ± 调整实例尺寸：以**当前实际显示宽度**为起点（自动模式下就是自动算出的
    /// 宽度），步进后切到手动模式——用户手动调过之后就不再被自适应覆盖。
    private func stepInstanceWidth(_ delta: Double) {
        let base = isAutoSizing ? Double(currentLayout.cardWidth) : instanceWidth
        instanceWidth = min(MatrixFit.maxCardWidth,
                            max(MatrixFit.minCardWidth, (base + delta).rounded(.down)))
        isAutoSizing = false
    }

    private var sizeReadout: String {
        guard !session.matrixAccounts.isEmpty else { return "" }
        return "\(Int(currentLayout.cardWidth))×\(Int(currentLayout.gameHeight))"
    }

    /// 尺寸控制胶囊：尺寸读数 + －/＋ + 自动/手动 + 每行窗口数菜单。
    private var sizeControlChip: some View {
        HStack(spacing: 5) {
            if !session.matrixAccounts.isEmpty {
                Text(sizeReadout)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .help(isAutoSizing
                          ? "自动适配：跟随画布大小，严格 9:16"
                          : "手动尺寸：点「自动」交回自适应")
            }
            Button {
                stepInstanceWidth(-20)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 9, intensity: 0.14)
            .help("缩小窗口（自动切到手动尺寸）")
            Button {
                stepInstanceWidth(20)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 9, intensity: 0.14)
            .help("放大窗口（自动切到手动尺寸）")
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isAutoSizing = true
                    fixedColumns = nil
                }
            } label: {
                Text("自动")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isAutoSizing ? Color.white : Color.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous)
                        .fill(isAutoSizing ? Color.cyan.opacity(0.72) : Color.cyan.opacity(0.12)))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
            .help("自动适配：按画布大小与实例数整屏排布，严格 9:16")
        }
    }

    /// 每行窗口数菜单：自动 / 每行 1~12 个。
    private var columnsMenu: some View {
        Menu {
            Button {
                fixedColumns = nil
            } label: {
                if fixedColumns == nil {
                    Label("自动", systemImage: "checkmark")
                } else {
                    Text("自动")
                }
            }
            Divider()
            ForEach(1...12, id: \.self) { count in
                Button {
                    fixedColumns = count
                } label: {
                    if fixedColumns == count {
                        Label("每行 \(count) 个", systemImage: "checkmark")
                    } else {
                        Text("每行 \(count) 个")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .bold))
                Text(fixedColumns.map { "每行 \($0) 个" } ?? "每行自动")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
        .help("指定每行显示的窗口数")
    }

    /// 一键开启当前已打开实例的同步（路由仍由中控按账号所属分组隔离）；
    /// 全开状态下点击 = 关闭全部分组同步。
    @ViewBuilder
    private var syncActionChip: some View {
        if !liveSyncAccountIDs.isEmpty {
            Button {
                if allLiveInstancesAreSyncing {
                    sync.disableAllSync()
                } else {
                    sync.enableAllLiveInstances()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: allLiveInstancesAreSyncing ? "link.circle.fill" : "link.circle")
                        .font(.system(size: 10, weight: .bold))
                    Text(allLiveInstancesAreSyncing ? "同步已全开" : "一键开启同步")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(allLiveInstancesAreSyncing ? Color.white : Color.cyan)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous)
                    .fill(allLiveInstancesAreSyncing ? Color.cyan.opacity(0.72) : Color.cyan.opacity(0.14)))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
            .help(allLiveInstancesAreSyncing
                  ? "关闭全部分组同步"
                  : "一键开启当前已打开的 \(liveSyncAccountIDs.count) 个实例；事件只在各自分组内同步")
        }
    }

    /// 分组同步摘要：多组同步 → 「同步 N 组 · M 窗口」（点击全关）；
    /// 单组 → 「组名 · 主控名 主控」（金）或「组名 · N 窗口」（青，点击关该组）；
    /// 无同步 → 不占位。
    @ViewBuilder
    private var syncStatusChip: some View {
        let activeGroups = session.groupDefinitions.filter { sync.isGroupSyncEnabled($0.id) }
        if activeGroups.count > 1 {
            Button {
                sync.disableAllSync()
            } label: {
                statusChipLabel(icon: "link.circle.fill",
                                text: "同步 \(activeGroups.count) 组 · \(sync.receiverCount) 窗口",
                                tint: .cyan)
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
            .help("当前有多个分组同步，点击关闭全部分组同步")
        } else if let group = activeGroups.first {
            let masterID = sync.masterAccountID(in: group.id)
            let masterName = masterID.flatMap { id in session.accounts.first { $0.id == id }?.nickname }
            Button {
                sync.disableGroup(group.id)
            } label: {
                statusChipLabel(
                    icon: masterName == nil ? "link.circle.fill" : "crown.fill",
                    text: masterName.map { "\(group.groupName) · \($0) 主控" }
                        ?? "\(group.groupName) · \(sync.receiverCount(in: group.id)) 窗口",
                    tint: masterName == nil ? .cyan : .yellow)
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
            .help("关闭「\(group.groupName)」分组同步")
        }
    }

    private func statusChipLabel(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
    }

    // MARK: - 画布

    @ViewBuilder
    private func canvas(entries: [GameAccount], layout: MatrixLayout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.cardWidth), spacing: MatrixFit.spacing),
                            count: layout.columns)
        ScrollView([.horizontal, .vertical]) {
            LazyVGrid(columns: columns, spacing: MatrixFit.spacing) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, account in
                    ViewportCardView(session: session,
                                     account: account,
                                     layout: layout,
                                     slotIndex: index,
                                     onHeaderDrag: headerDrag(_:),
                                     onHeaderDragEnded: headerDragEnded)
                        .frame(width: layout.cardWidth, height: layout.cardHeight)
                        // 格子身份 = 账号 + 重载代次 + **启动代次**。
                        // 后两者都是「强制重建」开关，各自对应一类必须换实例的动作：
                        // · reloadRevision：重新登录（格子不消失，只能靠改身份换格子）；
                        // · launchGeneration：关闭后再启动（格子消失过，但 SwiftUI 会
                        //   按 identity 复用旧格子——实测移出再放回同一 identity 既
                        //   不调 dismantleNSView 也不再调 makeNSView，于是池里永远
                        //   不新建实例，卡片上是那个已被拆除的旧 WebView = 空白）。
                        // 缺了启动代次，「退出 → 再登录」就是必现的「无法登录」。
                        .id("\(account.id)#\(session.reloadRevision)#\(session.launchGeneration(forAccountID: account.id))")
                }
            }
            .padding(MatrixCanvasMetrics.inner)
            .frame(minWidth: max(0, canvasViewport.width - MatrixCanvasMetrics.horizontalInset),
                   minHeight: max(0, canvasViewport.height - MatrixCanvasMetrics.verticalInset),
                   alignment: .center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("多开矩阵")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("从左侧账号库启动账号，游戏画面会出现在这里。\n多开时矩阵自动按 9:16 适配整屏。")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 矩阵卡片：顶栏（序号 / 昵称 / 👑 主控 / 🔗 参与同步 / 重载 / 关闭）
/// + 严格 9:16 游戏画面 + 分组着色描边（主控加流光）。
/// 标题栏支持拖拽换位（DragGesture + 布局快照命中测试）。
struct ViewportCardView: View {
    @ObservedObject var session: LobbySessionModel
    /// 群控中控：👑 / 🔗 两个开关都落在它身上。
    @ObservedObject private var sync: InputSyncController
    /// 抓包控制器：📡 按钮的高亮态（capturingAccountIDs）。
    @ObservedObject private var capture: PacketCaptureController
    let account: GameAccount
    let layout: MatrixLayout
    let slotIndex: Int
    /// 标题栏拖拽回调（舞台统一处理换位逻辑）。
    let onHeaderDrag: (DragGesture.Value) -> Void
    let onHeaderDragEnded: () -> Void

    init(session: LobbySessionModel,
         account: GameAccount,
         layout: MatrixLayout,
         slotIndex: Int,
         onHeaderDrag: @escaping (DragGesture.Value) -> Void,
         onHeaderDragEnded: @escaping () -> Void) {
        self.session = session
        self.account = account
        self.layout = layout
        self.slotIndex = slotIndex
        self.onHeaderDrag = onHeaderDrag
        self.onHeaderDragEnded = onHeaderDragEnded
        _sync = ObservedObject(wrappedValue: session.sync)
        _capture = ObservedObject(wrappedValue: session.capture)
    }

    private var isFocused: Bool { session.focusedAccountID == account.id }
    private var isDragging: Bool { session.draggingMatrixAccountID == account.id }
    private var isMaster: Bool { sync.isMaster(account.id) }
    private var isReceiver: Bool { sync.isReceiver(account.id) }
    /// 本实例是否在抓包（📡 按钮点亮）。
    private var isCapturing: Bool { capture.isCapturing(accountID: account.id) }
    private var swatch: (Double, Double, Double) {
        GroupSwatch.rgb(for: session.groupColorName(forAccountID: account.id))
    }
    private var groupColor: Color {
        Color(red: swatch.0, green: swatch.1, blue: swatch.2)
    }
    private var remark: String {
        session.remark(forAccountID: account.id)
    }
    /// 🔗 的提示文案随模式变化：无主控时它是「互相广播」的一份子，有主控时纯接收。
    private var participateHelp: String {
        let groupName = session.groupName(forAccountID: account.id)
        if isMaster { return "取消\(groupName)组主控" }
        if sync.masterAccountID(in: sync.groupID(for: account.id)) != nil {
            return isReceiver
                ? "关闭\(groupName)组参与同步（不再接收主控操作）"
                : "开启\(groupName)组参与同步（接收主控操作）"
        }
        return isReceiver
            ? "关闭\(groupName)组参与同步（本窗口不再参与互相同步）"
            : "开启\(groupName)组参与同步（与其它同组窗口互相同步）"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            gameSurface
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(groupColor.opacity(0.06))
        )
        .overlay {
            ZStack {
                // 分组着色描边：同组同色、不同组不同色；主控加粗。
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [groupColor.opacity(0.82), groupColor.opacity(0.42)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: isMaster ? 1.8 : 1.2
                    )
                LobbyMasterBorderEffect(color: groupColor, isActive: isMaster)
            }
        }
        .shadow(color: isDragging ? groupColor.opacity(0.45) :
                    (isFocused ? Color.yellow.opacity(0.22) : .black.opacity(0.4)),
                radius: isDragging ? 18 : (isFocused ? 14 : 10), y: 4)
        .scaleEffect(isDragging ? 1.03 : 1)
        .opacity(isDragging ? 0.92 : 1)
        // 布局帧上报（拖拽命中测试输入）。
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: MatrixCardFramesKey.self,
                    value: [account.id: geo.frame(in: .global)]
                )
            }
        )
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("\(slotIndex + 1)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 14, height: 14)
                .background(.white)
                .clipShape(Circle())
            Text(account.nickname)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !remark.isEmpty {
                Text(remark)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 3)
            // 盐场图表：弹独立悬浮窗口（可透明 / 置顶 / 鼠标穿透），展示盐场地图占领 + 战况。
            // 窗口开着时按钮点亮；打盐场时把图表窗压在实例上面当参考。
            Button {
                session.toggleSaltFieldChart(account)
            } label: {
                Image(systemName: session.saltFieldChartsVisible.contains(account.id) ? "map.fill" : "map")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(session.saltFieldChartsVisible.contains(account.id) ? Color.cyan : Color.white.opacity(0.45))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 4, intensity: 0.16)
            .help("盐场实时图表：独立悬浮窗口展示战场占领与击杀/复活战况（可调透明度、鼠标穿透，打盐场时不挡操作）")
            // 抓包：开/停本实例的 WSS 帧捕获并弹出独立抓包窗口；抓包中按钮点亮。
            Button {
                session.togglePacketCapture(account)
            } label: {
                Image(systemName: isCapturing ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isCapturing ? Color.orange : Color.white.opacity(0.45))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 4, intensity: 0.16)
            .help(isCapturing ? "停止抓包（窗口可继续查看 / 导出）" : "抓包：捕获本实例的 WSS 协议帧（独立窗口，支持命令过滤）")
            // 主控：在所属分组内唯一。点击设为本组主控或退位。
            // 没有本组主控时，本组开了同步的窗口互相同步。
            Button {
                sync.toggleMaster(account.id)
            } label: {
                Image(systemName: isMaster ? "crown.fill" : "crown")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isMaster ? Color.yellow : Color.white.opacity(0.5))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 4, intensity: 0.16)
            .help(isMaster ? "取消本组主控" : "设为本组主控：只有此窗口的操作会同步出去")
            // 参与同步：每个窗口独立开关。既是收件人；无本组主控时同时也是发言人。
            Button {
                sync.toggleReceiver(account.id)
            } label: {
                Image(systemName: isReceiver ? "link.circle.fill" : "link.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isReceiver ? Color.cyan : Color.white.opacity(0.45))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 4, intensity: 0.16)
            .help(participateHelp)
            Button {
                session.reload(account)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 8, intensity: 0.14)
            .help("重新登录")
            Button {
                session.close(account)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 8, intensity: 0.14)
            .help("关闭实例")
        }
        .padding(.horizontal, 7)
        .frame(height: layout.headerHeight)
        .background(Color.black.opacity(0.55))
        .contentShape(Rectangle())
        // 标题栏拖拽换位：minimumDistance 4 保证不抢按钮的点击。
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in onHeaderDrag(value) }
                .onEnded { _ in onHeaderDragEnded() }
        )
        .help("按住标题拖动可调整窗口位置")
    }

    private var gameSurface: some View {
        GameSurfaceRepresentable(session: session, account: account)
            .frame(width: layout.cardWidth, height: layout.gameHeight)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                session.focus(account.id)
                session.pool.existingSurface(forAccountID: account.id)?.focusWebView()
            }
    }
}

/// SwiftUI ↔ 实例桥：格子每次拿到的是池里同一个活视图。
/// ⚠️ `dismantleNSView` 故意什么都不做——滚动 / 重排 / 侧栏收放导致的格子
/// 销毁不能拆掉 WebKit 实例，否则切回来就要重新加载整局游戏。
/// 真正的销毁只在关闭实例和「重新登录」时由池执行。
struct GameSurfaceRepresentable: NSViewRepresentable {
    let session: LobbySessionModel
    let account: GameAccount

    func makeNSView(context: Context) -> NSView {
        session.pool.surface(for: account, environment: .multi)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 布局引擎自动调整尺寸，无需手动重算 frame。
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // 不 stop、不 removeFromSuperview（SwiftUI 自己会摘）。
    }
}

/// 主控卡片专用边框动效：同组颜色的呼吸辉光 + 沿圆角外框循环移动的流光。
/// 动画状态隔离在本视图内，避免每一帧动画都让 WKWebView 卡片主体重新计算。
struct LobbyMasterBorderEffect: View {
    let color: Color
    let isActive: Bool

    @State private var sweepAngle: Double = 0
    @State private var isBreathing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            if isActive {
                // 外层柔光：呼吸时变亮/变暗，强化「这是当前主控」的识别度。
                shape
                    .stroke(color.opacity(isBreathing ? 0.72 : 0.30), lineWidth: 6)
                    .blur(radius: 5)
                // 内层流光：高亮点沿卡片四周循环移动。
                shape
                    .strokeBorder(
                        AngularGradient(
                            colors: [color.opacity(0.16), color.opacity(0.78),
                                     Color.white.opacity(0.98), color.opacity(0.78),
                                     color.opacity(0.16)],
                            center: .center,
                            angle: .degrees(sweepAngle)
                        ),
                        lineWidth: isBreathing ? 2.4 : 1.6
                    )
                    .opacity(isBreathing ? 1 : 0.78)
            }
        }
        .allowsHitTesting(false)
        .onAppear { updateAnimation(isActive) }
        .onChange(of: isActive) { _, active in
            updateAnimation(active)
        }
    }

    private func updateAnimation(_ active: Bool) {
        guard active else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                sweepAngle = 0
                isBreathing = false
            }
            return
        }
        // 每次从普通卡片切为主控时从固定起点开始，避免接管后停在半截光带。
        sweepAngle = 0
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
            sweepAngle = 360
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            isBreathing = true
        }
    }
}
