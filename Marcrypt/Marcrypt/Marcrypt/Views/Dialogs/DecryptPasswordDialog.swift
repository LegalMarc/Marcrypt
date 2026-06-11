import SwiftUI
import MarcryptCore

struct DecryptPasswordDialog: View {
    let isRetry: Bool
    let onCancel: () -> Void
    let onDecrypt: (String) -> Void
    @ObservedObject var vm: FileViewModel // Access to file items for guessing
    
    @State private var password = ""
    @State private var showPassword = false
    @State private var isGuessing = false
    @State private var guessStatus = ""
    @State private var guessingTask: Task<Void, Never>?
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: isRetry ? "lock.open.trianglebadge.exclamationmark" : "lock.open.fill")
                    .font(.system(size: 42))
                    .foregroundColor(isRetry ? CustomColors.destructiveColor(for: colorScheme) : CustomColors.accentColor(for: colorScheme))
                
                Text(isRetry ? "Decryption Failed" : "Decrypt Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(isRetry ? "The password was incorrect for some files. Please try again." : "Enter the password to decrypt your files.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 10)
            
            // Interaction Area
            if isGuessing {
                // Guessing Progress UI
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(guessStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
	                    Button("Cancel Guessing") {
	                        guessingTask?.cancel()
	                        guessingTask = nil
	                        isGuessing = false
	                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .padding(.vertical, 20)
                .transition(.opacity)
            } else {
                // Password Entry UI
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if showPassword {
                                TextField("Password", text: $password)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("Password", text: $password)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            Button(action: { showPassword.toggle() }) {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Help Me Guess Button
                    Button(action: { startGuessing() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                            Text("Help Me Guess")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(CustomColors.accentColor(for: colorScheme))
                    .help("Try commonly used passwords from the dictionary")
                }
            }
            
            // Main Actions
            HStack(spacing: 12) {
	                Button("Cancel") {
	                    guessingTask?.cancel()
	                    guessingTask = nil
	                    onCancel()
	                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("Decrypt") { onDecrypt(password) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(CustomColors.accentColor(for: colorScheme))
                .disabled(password.isEmpty || isGuessing)
            }
        }
        .padding(32)
        .frame(width: 420)
	        .background(CustomColors.cardBackground(for: colorScheme))
	        .cornerRadius(16)
	        .shadow(radius: 10)
	        .onDisappear {
	            guessingTask?.cancel()
	            guessingTask = nil
	        }
    }
    
    private func startGuessing() {
        guard let sample = vm.items.first(where: { $0.status == .encrypted || $0.status == .decryptionFailed }) else {
            guessStatus = "No encrypted files to test."
            return
        }
        
        isGuessing = true
        guessStatus = "Loading dictionary..."

        guessingTask?.cancel()
        guessingTask = Task {
            let service = PasswordGuessingService.shared
            let candidates = service.loadCandidates()

            await MainActor.run { guessStatus = "Testing \(candidates.count) passwords..." }

            guard !Task.isCancelled else { return }
            if let found = await service.guessPassword(for: sample, candidates: candidates) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.password = found
                    self.isGuessing = false
                    self.guessingTask = nil
                    // Optional: Auto-submit? No, let user verify.
                }
            } else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.guessStatus = "Password not found in dictionary."
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isGuessing = false
                    self.guessingTask = nil
                }
            }
        }
    }
}
