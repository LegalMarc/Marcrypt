import SwiftUI
import AppKit

public struct CustomColors {
    // Adaptive color properties that respond to color scheme
    public static func appBackground(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor(calibratedHue: 0.58, saturation: 0.04, brightness: 0.98, alpha: 1.0))
        case .dark:
            // High Contrast Dark Mode (True Black/Dark Gray) for "Late Night Eyes" compliance
            return Color(red: 26/255, green: 27/255, blue: 38/255) // #1A1B26 (Deep Slate)
        @unknown default:
            return Color(NSColor(calibratedHue: 0.58, saturation: 0.04, brightness: 0.98, alpha: 1.0))
        }
    }

    public static func contentBackground(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor(calibratedHue: 0.58, saturation: 0.07, brightness: 0.93, alpha: 1.0))
        case .dark:
            // Dark Gray for content areas
            return Color(red: 36/255, green: 40/255, blue: 59/255) // #24283B (Lighter Slate)
        @unknown default:
            return Color(NSColor(calibratedHue: 0.58, saturation: 0.07, brightness: 0.93, alpha: 1.0))
        }
    }

    public static func accentColor(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor(calibratedHue: 0.53, saturation: 0.60, brightness: 0.68, alpha: 1.0))
        case .dark:
            // High contrast vibrant blue
            return Color(red: 59/255, green: 130/255, blue: 246/255) // #3B82F6 (Vibrant Blue)
        @unknown default:
            return Color(NSColor(calibratedHue: 0.53, saturation: 0.60, brightness: 0.68, alpha: 1.0))
        }
    }

    public static func destructiveColor(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1.0))
        case .dark:
            return Color(red: 248/255, green: 113/255, blue: 113/255) // #F87171 (Red)
        @unknown default:
            return Color(NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1.0))
        }
    }

    public static func primaryText(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor.labelColor)
        case .dark:
            // Pure White for max contrast
            return Color.white
        @unknown default:
            return Color(NSColor.labelColor)
        }
    }

    public static func secondaryText(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor.secondaryLabelColor)
        case .dark:
            // Light Gray
            return Color(red: 161/255, green: 172/255, blue: 184/255) // #A1ACB8
        @unknown default:
            return Color(NSColor.secondaryLabelColor)
        }
    }

    public static func shadow(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.black.opacity(0.12)
        case .dark:
            return Color(red: 19/255, green: 20/255, blue: 28/255).opacity(0.6)
        @unknown default:
            return Color.black.opacity(0.12)
        }
    }

    public static func subtleBorder(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.black.opacity(0.1)
        case .dark:
            // Crisp border for definition
            return Color(red: 86/255, green: 95/255, blue: 137/255).opacity(0.3)
        @unknown default:
            return Color.black.opacity(0.1)
        }
    }

    public static func cardBackground(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(NSColor.windowBackgroundColor)
        case .dark:
             return Color(red: 36/255, green: 40/255, blue: 59/255) // Match Content Background
        @unknown default:
            return Color(NSColor.windowBackgroundColor)
        }
    }

    // Legacy static properties for compatibility with existing code.
    // NOTE: This hardcodes them to light mode values if accessed statically.
    // It's recommended to update call sites to use `(for: colorScheme)` where possible
    // or rely on SwiftUI's environment handling if simple `.primary` / `.secondary` works.
    // But for our specific "Premium" colors that don't map 1:1 to system colors, we default to light
    // if the caller doesn't provide a scheme, or simply provide the light variant as the default.
    public static let appBackground = appBackground(for: .light)
    public static let contentBackground = contentBackground(for: .light)
    public static let accentColor = accentColor(for: .light)
    public static let destructiveColor = destructiveColor(for: .light)
    
    // For text, we can just defer to the functions or standard system behaviors if we want
    // but the previous code expected static properties.
    public static let primaryText = primaryText(for: .light)
    public static let secondaryText = secondaryText(for: .light)
    public static let shadow = shadow(for: .light)
    public static let subtleBorder = subtleBorder(for: .light)
    public static let cardBackground = cardBackground(for: .light)
}
