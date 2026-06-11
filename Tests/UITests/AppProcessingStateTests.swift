import XCTest
@testable import Marcrypt

@MainActor
final class AppProcessingStateTests: XCTestCase {
    func testBatchInfoUpdatesSharedProcessingState() {
        let viewModel = FileViewModel()
        
        viewModel.batchInfo = FileViewModel.BatchProgressInfo(
            processed: 0,
            total: 1,
            successCount: 0,
            failedCount: 0,
            isProcessing: true
        )
        XCTAssertTrue(AppProcessingState.shared.isProcessing)
        
        viewModel.batchInfo?.isProcessing = false
        XCTAssertFalse(AppProcessingState.shared.isProcessing)
        
        viewModel.batchInfo = nil
        XCTAssertFalse(AppProcessingState.shared.isProcessing)
    }
}
