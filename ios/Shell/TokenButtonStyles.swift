import SwiftUI

struct TokenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let tokens = DesignTokens.shared
        configuration.label
            .font(tokens.font(.lg, weight: .semibold))
            .foregroundStyle(tokens.color(.textPrimary))
            .padding(.horizontal, tokens.spacing(.lg))
            .padding(.vertical, tokens.spacing(.md))
            .background(configuration.isPressed ? tokens.color(.accent) : tokens.color(.primaryButton))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct TokenSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let tokens = DesignTokens.shared
        configuration.label
            .font(tokens.font(.lg, weight: .medium))
            .foregroundStyle(tokens.color(.textPrimary))
            .padding(.horizontal, tokens.spacing(.lg))
            .padding(.vertical, tokens.spacing(.md))
            .background(tokens.color(.card))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            .overlay {
                RoundedRectangle(cornerRadius: tokens.radius(.control))
                    .stroke(tokens.color(.border))
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct TokenIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let tokens = DesignTokens.shared
        configuration.label
            .foregroundStyle(tokens.color(.textPrimary))
            .padding(tokens.spacing(.md))
            .background(tokens.color(.primaryButton))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.icon)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
