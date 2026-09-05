import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        let tokens = DesignTokens.shared
        let columns = [GridItem(.flexible(), spacing: tokens.spacing(.md)), GridItem(.flexible(), spacing: tokens.spacing(.md))]

        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
                HStack(spacing: tokens.spacing(.md)) {
                    VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                        Text("多开工位")
                            .font(tokens.font(.xxl, weight: .semibold))
                            .foregroundStyle(tokens.color(.textPrimary))
                        Text("\(viewModel.items.count) 个活跃实例")
                            .font(tokens.font(.md))
                            .foregroundStyle(tokens.color(.textSecondary))
                    }
                    Spacer()
                }

                if viewModel.items.isEmpty {
                    WorkspaceEmptyState()
                } else {
                    LazyVGrid(columns: columns, spacing: tokens.spacing(.md)) {
                        ForEach(viewModel.items) { item in
                            WorkspaceCard(
                                item: item,
                                isSelected: viewModel.selectedID == item.id,
                                onSelect: { viewModel.selectedID = item.id },
                                onPause: { Task { await viewModel.pause(id: item.id) } },
                                onResume: { Task { await viewModel.resume(id: item.id) } },
                                onSnapshot: { Task { await viewModel.captureSnapshot(id: item.id) } },
                                onClose: { Task { await viewModel.close(id: item.id) } }
                            )
                        }
                    }
                }
            }
            .padding(tokens.spacing(.xl))
        }
        .background(tokens.color(.canvas))
    }
}

private struct WorkspaceEmptyState: View {
    var body: some View {
        let tokens = DesignTokens.shared
        VStack(spacing: tokens.spacing(.md)) {
            Image(systemName: "square.grid.2x2")
                .font(tokens.font(.xxl))
                .foregroundStyle(tokens.color(.textMuted))
            Text("尚未启动实例")
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
            Text("在账号库选择账号后启动多开。")
                .font(tokens.font(.md))
                .foregroundStyle(tokens.color(.textSecondary))
        }
        .frame(maxWidth: .infinity)
        .padding(tokens.spacing(.xl))
        .background(tokens.color(.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
    }
}

private struct WorkspaceCard: View {
    let item: WorkspaceItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onSnapshot: () -> Void
    let onClose: () -> Void

    var body: some View {
        let tokens = DesignTokens.shared

        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            HStack(spacing: tokens.spacing(.sm)) {
                Circle()
                    .fill(stateColor(tokens: tokens))
                    .frame(width: tokens.spacing(.sm), height: tokens.spacing(.sm))
                Text(item.account.nickname)
                    .font(tokens.font(.xl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                Spacer()
                Text(stateTitle)
                    .font(tokens.font(.sm, weight: .medium))
                    .foregroundStyle(tokens.color(.textSecondary))
            }

            VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                Text(item.account.gameName)
                    .font(tokens.font(.lg))
                    .foregroundStyle(tokens.color(.textPrimary))
                Text(item.latestSnapshot == nil ? "实时渲染等待接入" : "最近快照已更新")
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.textMuted))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(tokens.spacing(.lg))
            .background(tokens.color(.panel))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))

            HStack(spacing: tokens.spacing(.sm)) {
                if item.host.state == .running {
                    Button("暂停", action: onPause).buttonStyle(TokenSecondaryButtonStyle())
                } else if item.host.state == .paused {
                    Button("继续", action: onResume).buttonStyle(TokenSecondaryButtonStyle())
                }
                Button("快照", action: onSnapshot).buttonStyle(TokenSecondaryButtonStyle())
                Spacer()
                Button("关闭", action: onClose)
                    .font(tokens.font(.lg, weight: .medium))
                    .foregroundStyle(tokens.color(.danger))
            }
        }
        .padding(tokens.spacing(.lg))
        .background(isSelected ? tokens.color(.cardRaised) : tokens.color(.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
        .overlay {
            RoundedRectangle(cornerRadius: tokens.radius(.card))
                .stroke(isSelected ? tokens.color(.accent) : tokens.color(.border))
        }
        .contentShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
        .onTapGesture(perform: onSelect)
    }

    private var stateTitle: String {
        switch item.host.state {
        case .idle: return "空闲"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .snapshotting: return "快照中"
        case .closing: return "关闭中"
        case .failed: return "失败"
        }
    }

    private func stateColor(tokens: DesignTokens) -> Color {
        switch item.host.state {
        case .running: return tokens.color(.success)
        case .failed: return tokens.color(.danger)
        default: return tokens.color(.textMuted)
        }
    }
}
