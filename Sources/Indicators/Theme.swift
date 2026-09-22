import SwiftUI
import IndicatorsCore

enum Theme {
    static func accent(for provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openai: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .grok: return Color.primary.opacity(0.75)
        }
    }

    static func level(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return Color(red: 0.20, green: 0.70, blue: 0.40)
        case ..<85: return Color(red: 0.95, green: 0.65, blue: 0.15)
        default: return Color(red: 0.90, green: 0.25, blue: 0.25)
        }
    }

    static let cardBackground = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.08)
}

struct ProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 22

    var body: some View {
        Text(provider.tag)
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.accent(for: provider)))
    }
}

struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Theme.level(percent))
                    .frame(width: max(geo.size.width * CGFloat(min(percent, 100) / 100), percent > 0 ? 4 : 0))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.35), value: percent)
    }
}
