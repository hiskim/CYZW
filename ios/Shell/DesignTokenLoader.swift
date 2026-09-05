import Foundation
import SwiftUI

enum DesignColorToken: String, CaseIterable {
    case canvas
    case card
    case cardRaised = "card-raised"
    case panel
    case border
    case accent
    case primaryButton = "primary-button"
    case textPrimary = "text-primary"
    case textSecondary = "text-secondary"
    case textMuted = "text-muted"
    case success
    case danger
}

enum DesignSpacingToken: String {
    case sm, md, lg, xl
}

enum DesignRadiusToken: String {
    case card, control, icon, pill
}

enum DesignFontToken: String, CaseIterable {
    case xs, sm, md, lg, xl, xxl
}

@MainActor
final class DesignTokens {
    static let shared = DesignTokens()

    private let values: [String: String]

    private init() {
        values = DesignTokenLoader.loadRootCustomProperties()
    }

    func color(_ token: DesignColorToken) -> Color {
        Color(hex: values["--color-\(token.rawValue)"] ?? "#000000")
    }

    func spacing(_ token: DesignSpacingToken) -> CGFloat {
        cssPixels(values["--space-\(token.rawValue)"] ?? "0px")
    }

    func radius(_ token: DesignRadiusToken) -> CGFloat {
        cssPixels(values["--radius-\(token.rawValue)"] ?? "0px")
    }

    func fontSize(_ token: DesignFontToken) -> CGFloat {
        cssPixels(values["--font-\(token.rawValue)"] ?? "0px")
    }

    func font(_ token: DesignFontToken, weight: Font.Weight = .regular) -> Font {
        .system(size: fontSize(token), weight: weight)
    }

    private func cssPixels(_ value: String) -> CGFloat {
        CGFloat(Double(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "px", with: "")) ?? 0)
    }
}

enum DesignTokenLoader {
    static func loadRootCustomProperties(bundle: Bundle = .main) -> [String: String] {
        let css = loadCSS(bundle: bundle) ?? fallbackCSS
        guard let rootRange = css.range(of: #":root\s*\{([\s\S]*?)\}"#, options: .regularExpression) else {
            return parseDeclarations(from: fallbackCSS)
        }
        return parseDeclarations(from: String(css[rootRange]))
    }

    private static func loadCSS(bundle: Bundle) -> String? {
        let url = bundle.url(forResource: "design-tokens", withExtension: "css", subdirectory: "shared")
            ?? bundle.url(forResource: "design-tokens", withExtension: "css")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func parseDeclarations(from source: String) -> [String: String] {
        let pattern = #"(--[A-Za-z0-9-]+)\s*:\s*([^;{}]+);"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { return }
            result[String(source[keyRange])] = String(source[valueRange])
        }
    }

    private static let fallbackCSS = """
    :root {
      --color-canvas: #000000; --color-card: #1C1C1F; --color-card-raised: #29292B;
      --color-panel: #262626; --color-border: #3B3B3D; --color-accent: #2996FF;
      --color-primary-button: #0066CC; --color-text-primary: #FFFFFF;
      --color-text-secondary: #8F8F94; --color-text-muted: #6E6E73;
      --color-success: #30D159; --color-danger: #FF453B;
      --space-sm: 8px; --space-md: 12px; --space-lg: 16px; --space-xl: 20px;
      --radius-card: 18px; --radius-control: 12px; --radius-icon: 14px; --radius-pill: 9999px;
      --font-xs: 11px; --font-sm: 12px; --font-md: 13px; --font-lg: 14px; --font-xl: 15px; --font-xxl: 22px;
    }
    """
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(value, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }
}
