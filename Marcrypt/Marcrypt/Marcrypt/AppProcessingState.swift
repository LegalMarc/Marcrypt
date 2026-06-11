import Combine
import Foundation

@MainActor
final class AppProcessingState: ObservableObject {
    static let shared = AppProcessingState()
    
    @Published var isProcessing = false
    
    private init() {}
}
