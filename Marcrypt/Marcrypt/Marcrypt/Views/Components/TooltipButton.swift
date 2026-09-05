import SwiftUI
import MarcryptCore

/// A reusable tooltip button with a hover-delayed popover.
/// Accent-colored icon button with hover scale animation and rich help tooltip.
struct TooltipButton: View {
    let action: () -> Void
    let iconView: (Color) -> AnyView
    let tooltip: String
    let description: String
    var isEnabled: Bool = true
    let iconName: String?
    let accessibilityId: String?

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        action: @escaping () -> Void,
        icon: String,
        tooltip: String,
        description: String,
        isEnabled: Bool = true,
        accessibilityId: String? = nil
    ) {
        self.action = action
        self.tooltip = tooltip
        self.description = description
        self.isEnabled = isEnabled
        self.iconName = icon
        self.accessibilityId = accessibilityId
        self.iconView = { color in
            AnyView(
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color)
            )
        }
    }

    var body: some View {
        let iconColor = isEnabled ? CustomColors.accentColor(for: colorScheme) : Color.gray.opacity(0.4)
        return buttonView(iconColor: iconColor)
    }

    @ViewBuilder
    private func buttonView(iconColor: Color) -> some View {
        let baseButton = Button(action: isEnabled ? action : {}) {
            ZStack {
                iconView(iconColor)
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = isEnabled ? hovering : false
        }
        .help(isEnabled ? "\(tooltip): \(description)" : "\(tooltip): Not available")

        if let accessibilityId {
            baseButton.accessibilityIdentifier(accessibilityId)
        } else {
            baseButton
        }
    }
}
