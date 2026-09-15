import SwiftUI
import LobbyDomain
import LobbyEngine

/// 多开矩阵舞台：画布测量 → 求解器算尺寸 → LazyVGrid 摆卡片。
///
/// 数据源红线：适配计数与 ForEach 渲染必须共用 `session.matrixAccounts`——
/// 任何一边多算 / 漏算，卡片尺寸都会错。
struct MatrixStageView: View {
    @ObservedObject var session: LobbySessionModel
    /// 画布可视区尺寸（自动适配的输入；首帧为 0，随后立即被真实尺寸覆盖）。
    @State private var canvasViewport: CGSize = .zero

    var body: some View {
        let entries = session.matrixAccounts
        let layout = MatrixFit.fit(count: entries.count,
                                   in: MatrixCanvasMetrics.contentSize(from: canvasViewport))
        ZStack {
            canvas(entries: entries, layout: layout)
            if entries.isEmpty {
                emptyState
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { canvasViewport = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in
                        canvasViewport = newSize
                    }
            }
        )
        .confirmationDialog(
            "删除账号",
            isPresented: Binding(
                get: { session.deletionCandidate != nil },
                set: { if !$0 { session.deletionCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(session.deletionCandidate?.nickname ?? "")」", role: .destructive) {
                session.confirmDelete()
            }
            Button("取消", role: .cancel) { session.deletionCandidate = nil }
        } message: {
            Text("凭据文件将被永久删除，且不可恢复。若该账号正在运行，实例会先被关闭。")
        }
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
                                     slotIndex: index)
                        .frame(width: layout.cardWidth, height: layout.cardHeight)
                        .id("\(account.id)#\(session.reloadRevision)")
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

/// 矩阵卡片：顶栏（昵称 / 重载 / 关闭）+ 严格 9:16 游戏画面 + 焦点描边。
struct ViewportCardView: View {
    @ObservedObject var session: LobbySessionModel
    let account: GameAccount
    let layout: MatrixLayout
    let slotIndex: Int

    private var isFocused: Bool { session.focusedAccountID == account.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            gameSurface
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? Color.yellow.opacity(0.85) : Color.white.opacity(0.10),
                              lineWidth: isFocused ? 1.5 : 1)
        )
        .shadow(color: isFocused ? Color.yellow.opacity(0.22) : .black.opacity(0.4),
                radius: isFocused ? 14 : 10, y: 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(isFocused ? .yellow : .secondary)
            Text(account.nickname)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                session.reload(account)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 9, intensity: 0.14)
            .help("重新登录")
            Button {
                session.close(account)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 9, intensity: 0.14)
            .help("关闭实例")
        }
        .padding(.horizontal, 8)
        .frame(height: layout.headerHeight)
        .background(Color.black.opacity(0.55))
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
