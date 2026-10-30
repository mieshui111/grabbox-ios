import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 设计令牌（与 Android 版一致的色板，深色克制风）
enum Theme {
    static let bg = Color(hex: 0x080B11)
    static let card = Color(hex: 0x0E141E)
    static let stroke = Color(hex: 0x1B2430)
    static let input = Color(hex: 0x111927)
    static let chip = Color(hex: 0x141D2A)

    static let textPrimary = Color(hex: 0xEAF0FA)
    static let textSecondary = Color(hex: 0x8A9AB0)
    static let textTertiary = Color(hex: 0x5B6A80)

    static let brandA = Color(hex: 0x4C7DFF)
    static let brandB = Color(hex: 0x22D3EE)
    static let ok = Color(hex: 0x34D399)
    static let warn = Color(hex: 0xF59E0B)
    static let error = Color(hex: 0xF87171)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandA, brandB],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var titleGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0xEAF0FA), Color(hex: 0xC7D6EE), Color(hex: 0x6FD8F0)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
