import SwiftUI
import UIKit

/// Brand accents only. Surfaces, body text and destructive states keep system colors.
enum SnapScheduleStyle {
    static let actionUIColor = adaptive(light: 0x006B68, dark: 0x70DDD0,
                                        lightContrast: 0x005450, darkContrast: 0xA2F4E8)
    static let emphasisUIColor = adaptive(light: 0x345BC3, dark: 0xA9BFFF,
                                          lightContrast: 0x26469C, darkContrast: 0xCCD8FF)
    static let action = Color(uiColor: actionUIColor)
    static let emphasis = Color(uiColor: emphasisUIColor)
    // UICalendarView keeps its selected day white; its fill needs a darker Dark Mode tint.
    static let calendarUIColor = adaptive(light: 0x006B68, dark: 0x237E78,
                                          lightContrast: 0x005450, darkContrast: 0x237E78)
    static let calendar = Color(uiColor: calendarUIColor)
    // A filled CTA keeps white text readable in both appearances.
    static let actionFill = Color(uiColor: adaptive(light: 0x006B68, dark: 0x006B68,
                                                   lightContrast: 0x005450, darkContrast: 0x005450))

    private static func adaptive(light: UInt32, dark: UInt32,
                                 lightContrast: UInt32, darkContrast: UInt32) -> UIColor {
        UIColor { traits in
            let highContrast = traits.accessibilityContrast == .high
            let value = traits.userInterfaceStyle == .dark
                ? (highContrast ? darkContrast : dark)
                : (highContrast ? lightContrast : light)
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}

struct SnapSectionTitle: View {
    @Environment(\.snapCompactTypography) private var compact
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(SnapScheduleStyle.action)
        }
        .font(compact ? .subheadline.weight(.semibold) : .headline)
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

extension View {
    func snapPrimaryAction() -> some View {
        self
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .tint(SnapScheduleStyle.actionFill)
            .foregroundStyle(.white)
    }
}

// Compact titles keep the content hierarchy without shrinking body text or Dynamic Type.
private struct SnapCompactTypographyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapCompactTypography: Bool {
        get { self[SnapCompactTypographyKey.self] }
        set { self[SnapCompactTypographyKey.self] = newValue }
    }
}
