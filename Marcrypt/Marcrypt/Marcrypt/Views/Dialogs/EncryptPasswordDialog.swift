import SwiftUI
import MarcryptCore

struct EncryptPasswordDialog: View {
    let isRetry: Bool
    let onCancel: () -> Void
    let onEncrypt: (String) -> Void  // Now takes password as parameter
    
    // Local secure password storage
    @State private var localPassword = ""
    @State private var localPasswordConfirm = ""
    @State private var localShowPasswordText = false
    @Environment(\.colorScheme) var colorScheme
    
    private func calculatePasswordEntropy(_ password: String) -> Double {
        guard !password.isEmpty else { return 0.0 }
        
        var characterSets: Set<Character> = []
        var poolSize = 0
        
        let lowercase = CharacterSet.lowercaseLetters
        let uppercase = CharacterSet.uppercaseLetters
        let digits = CharacterSet.decimalDigits
        let symbols = CharacterSet.punctuationCharacters.union(CharacterSet.symbols)
        
        for char in password {
            guard let scalar = char.unicodeScalars.first else { continue }
            if lowercase.contains(scalar) {
                characterSets.insert("a")
            } else if uppercase.contains(scalar) {
                characterSets.insert("A")
            } else if digits.contains(scalar) {
                characterSets.insert("0")
            } else if symbols.contains(scalar) {
                characterSets.insert("!")
            }
        }
        
        if characterSets.contains("a") { poolSize += 26 }
        if characterSets.contains("A") { poolSize += 26 }
        if characterSets.contains("0") { poolSize += 10 }
        if characterSets.contains("!") { poolSize += 32 }
        
        // Prevent log2 crashes with invalid pool sizes
        guard poolSize > 1 else { return 0.0 }
        
        return log2(Double(poolSize)) * Double(password.count)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text(isRetry ? "Encryption Failed - Try Different Password" : "Set Encryption Password")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(CustomColors.primaryText(for: colorScheme))
                
                Text(isRetry ? "Some or all files failed to encrypt. Please try a different password or cancel to stop." : "Enter a password to encrypt the PDF files. The same password will be applied to all files.")
                    .font(.body)
                    .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
            }
            
            // Security Label
            HStack(spacing: 6) {
                Image(systemName: "shield.check.fill")
                    .font(.system(size: 10))
                    .foregroundColor(CustomColors.accentColor(for: colorScheme))
                Text("Strong password encryption applies to all files")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            .padding(.top, -4)
            
            VStack(spacing: 16) {
                // Password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.headline)
                        .foregroundColor(CustomColors.primaryText(for: colorScheme))
                    
                    HStack {
                         if localShowPasswordText {
                             TextField("Enter password", text: $localPassword)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         } else {
                             SecureField("Enter password", text: $localPassword)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         }
                         
                         Button(action: { localShowPasswordText.toggle() }) {
                             Image(systemName: localShowPasswordText ? "eye.slash" : "eye")
                                 .foregroundColor(CustomColors.accentColor(for: colorScheme))
                         }
                         .buttonStyle(.plain)
                     }
                }
                
                // Confirm password field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm Password")
                        .font(.headline)
                        .foregroundColor(CustomColors.primaryText(for: colorScheme))
                    
                    HStack {
                         if localShowPasswordText {
                             TextField("Confirm password", text: $localPasswordConfirm)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         } else {
                             SecureField("Confirm password", text: $localPasswordConfirm)
                                 .textFieldStyle(.roundedBorder)
                                 .disableAutocorrection(true)
                         }
                         
                         Button(action: { localShowPasswordText.toggle() }) {
                             Image(systemName: localShowPasswordText ? "eye.slash" : "eye")
                                 .foregroundColor(CustomColors.accentColor(for: colorScheme))
                         }
                         .buttonStyle(.plain)
                     }
                }
                
                 // Password strength meter
                 let entropy = calculatePasswordEntropy(localPassword)
                 
                     VStack(alignment: .leading, spacing: 8) {
                         Text("Password Strength")
                             .font(.headline)
                             .foregroundColor(CustomColors.primaryText(for: colorScheme))
                         
                         HStack(spacing: 4) {
                             ForEach(0..<5, id: \.self) { index in
                                 let thresholds: [Double] = [1, 40, 60, 120, 200]
                                 let colors: [Color] = [.red, .orange, .yellow, .green.opacity(0.7), .green]
                                 
                                 RoundedRectangle(cornerRadius: 2)
                                     .fill(entropy >= thresholds[index] ? colors[index] : Color.gray.opacity(0.3))
                                     .frame(height: 8)
                             }
                         }
                         
                         HStack {
                             Text("Horrible")
                                 .font(.caption2)
                                 .foregroundColor(.red)
                             Spacer()
                             Text("Poor")
                                 .font(.caption2)
                             Spacer()
                             Text("Not Great")
                                 .font(.caption2)
                             Spacer()
                             Text("Good")
                                 .font(.caption2)
                             Spacer()
                             Text("Excellent")
                                 .font(.caption2)
                         }
                     .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                     
                     Text("\(Int(entropy)) bits of entropy")
                         .font(.caption)
                         .foregroundColor(CustomColors.secondaryText(for: colorScheme))
                 }
            }
            
             // Buttons
             HStack(spacing: 12) {
                 Button("Cancel") {
                     // Secure cleanup before canceling
                     clearPasswords()
                     onCancel()
                 }
                 .buttonStyle(.bordered)
                 .controlSize(.large)
                 .tint(CustomColors.destructiveColor(for: colorScheme))
                 
                 Button(isRetry ? "Try Again" : "Encrypt") {
                    // Pass password directly and clear local state
                    onEncrypt(localPassword)
                    clearPasswords()
                }
                 .buttonStyle(.borderedProminent)
                 .controlSize(.large)
                 .tint(CustomColors.accentColor(for: colorScheme))
                 .disabled(localPassword.isEmpty || localPassword != localPasswordConfirm)
             }
        }
        .padding(32)
        .frame(maxWidth: 500)
        .background(CustomColors.cardBackground(for: colorScheme))
        .cornerRadius(16)
        .shadow(color: CustomColors.shadow(for: colorScheme), radius: 20, x: 0, y: 10)

        .onDisappear {
            // Secure cleanup when dialog is dismissed
            clearPasswords()
        }
    }
    
    private func clearPasswords() {
        // Overwrite before clearing for enhanced security
        let len1 = localPassword.count
        let len2 = localPasswordConfirm.count
        localPassword = String(repeating: " ", count: len1)
        localPasswordConfirm = String(repeating: " ", count: len2)
        localPassword = ""
        localPasswordConfirm = ""
        localShowPasswordText = false
    }
}
