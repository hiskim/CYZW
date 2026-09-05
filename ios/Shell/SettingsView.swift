import Combine
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    enum AccentChoice: String, CaseIterable, Identifiable {
        case accent
        case primaryButton
        case success

        var id: String { rawValue }

        var label: String {
            switch self {
            case .accent: return "强调蓝"
            case .primaryButton: return "主按钮蓝"
            case .success: return "成功绿"
            }
        }

        var token: DesignColorToken {
            switch self {
            case .accent: return .accent
            case .primaryButton: return .primaryButton
            case .success: return .success
            }
        }
    }

    enum PerformanceProfile: String, CaseIterable, Identifiable {
        case balanced
        case performance
        case batterySaver

        var id: String { rawValue }

        var label: String {
            switch self {
            case .balanced: return "均衡"
            case .performance: return "性能优先"
            case .batterySaver: return "省电"
            }
        }
    }

    @Published var accentChoice: AccentChoice = .accent
    @Published var fontToken: DesignFontToken = .lg
    @Published var performanceProfile: PerformanceProfile = .balanced
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        let tokens = DesignTokens.shared
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
                Text("设置")
                    .font(tokens.font(.xxl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))

                TokenSettingsCard(title: "主题色") {
                    Picker("主题色", selection: $viewModel.accentChoice) {
                        ForEach(SettingsViewModel.AccentChoice.allCases) { choice in
                            HStack(spacing: tokens.spacing(.sm)) {
                                Circle()
                                    .fill(tokens.color(choice.token))
                                    .frame(width: tokens.spacing(.md), height: tokens.spacing(.md))
                                Text(choice.label).font(tokens.font(.lg))
                            }
                            .tag(choice)
                        }
                    }
                    .font(tokens.font(.lg))
                    .tint(tokens.color(.accent))
                }

                TokenSettingsCard(title: "字号") {
                    Picker("字号", selection: $viewModel.fontToken) {
                        ForEach(DesignFontToken.allCases, id: \.self) { token in
                            Text("\(token.rawValue) · \(Int(tokens.fontSize(token)))px")
                                .font(tokens.font(token))
                                .tag(token)
                        }
                    }
                    .font(tokens.font(.lg))
                    .tint(tokens.color(.accent))
                    Text("预览文本")
                        .font(tokens.font(viewModel.fontToken))
                        .foregroundStyle(tokens.color(.textPrimary))
                }

                TokenSettingsCard(title: "性能档位") {
                    Picker("性能档位", selection: $viewModel.performanceProfile) {
                        ForEach(SettingsViewModel.PerformanceProfile.allCases) { profile in
                            Text(profile.label)
                                .font(tokens.font(.lg))
                                .tag(profile)
                        }
                    }
                    .font(tokens.font(.lg))
                    .tint(tokens.color(.accent))
                }
            }
            .padding(tokens.spacing(.xl))
        }
        .background(tokens.color(.canvas))
    }
}

private struct TokenSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        let tokens = DesignTokens.shared
        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            Text(title)
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
            content
                .foregroundStyle(tokens.color(.textSecondary))
        }
        .padding(tokens.spacing(.lg))
        .background(tokens.color(.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
        .overlay {
            RoundedRectangle(cornerRadius: tokens.radius(.card))
                .stroke(tokens.color(.border))
        }
    }
}
