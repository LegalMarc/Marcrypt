import SwiftUI
import MarcryptCore

struct FooterView: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("Released by Marc Mandel under the MIT license at ")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                Link("github.com/LegalMarc/Marcrypt", destination: Constants.githubURL)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.accentColor(for: colorScheme)) // Use accent color for links
            }
            .lineLimit(1)
            .truncationMode(.tail)
            
            HStack(spacing: 0) {
                Text("Got bugs? Message me at ")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                Link("linkedin.com/in/marcmandel/", destination: Constants.linkedInURL)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CustomColors.accentColor(for: colorScheme)) // Use accent color for links
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
}
