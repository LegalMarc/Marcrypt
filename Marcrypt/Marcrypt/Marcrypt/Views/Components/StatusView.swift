import SwiftUI
import MarcryptCore

struct StatusView: View {
    let status: ProcessingStatus
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Group {
            switch status {
            case .checking:         
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            case .encrypted:        
                Text("[Encrypted]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(CustomColors.destructiveColor(for: colorScheme))
                    )
            case .notEncrypted:     
                Text("[Not Encrypted]")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.secondaryText(for: colorScheme).opacity(0.1))
                    )
            case .corrupted:        
                Text("[Corrupted]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.destructiveColor(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.destructiveColor(for: colorScheme).opacity(0.1))
                    )
            case .decrypted:        
                Text("[Decryption Succeeded]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.accentColor(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.accentColor(for: colorScheme).opacity(0.15))
                    )
            case .decryptionFailed: 
                Text("[Decryption Failed]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.destructiveColor(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.destructiveColor(for: colorScheme).opacity(0.1))
                    )
            case .encryptionSucceeded:
                Text("[Encryption Succeeded]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.accentColor(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.accentColor(for: colorScheme).opacity(0.15))
                    )
            case .encryptionFailed:
                Text("[Encryption Failed]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.destructiveColor(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.destructiveColor(for: colorScheme).opacity(0.1))
                    )
            case .processing:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 12, height: 12)
                    Text("[Processing...]")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(CustomColors.accentColor(for: colorScheme))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CustomColors.accentColor(for: colorScheme).opacity(0.1))
                )
            case .watermarked:
                Text("[Watermarked]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.indigo.opacity(0.1))
                    )
            case .watermarkedEncrypted:
                Text("[Watermarked, Encrypted]")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CustomColors.accentColor(for: colorScheme)) // Green/Blue
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CustomColors.accentColor(for: colorScheme).opacity(0.15))
                    )
            }
        }
        .transition(.opacity.combined(with: .scale))
    }
}
