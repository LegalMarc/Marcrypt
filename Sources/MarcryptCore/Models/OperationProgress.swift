import Foundation

/// Lightweight progress value used by long-running core services.
public struct OperationProgress: Sendable, Equatable {
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64
    public let message: String?

    public init(completedUnitCount: Int64, totalUnitCount: Int64, message: String? = nil) {
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = max(0, totalUnitCount)
        self.message = message
    }

    public var fractionCompleted: Double? {
        guard totalUnitCount > 0 else { return nil }
        return min(1.0, max(0.0, Double(completedUnitCount) / Double(totalUnitCount)))
    }
}

public typealias OperationProgressHandler = @Sendable (OperationProgress) -> Void
