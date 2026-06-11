import XCTest
@testable import MarcryptCore

final class TestAuditService: XCTestCase {
    
    override func setUp() {
        super.setUp()
        AuditService.shared.clearSessionEvents()
    }
    
    func testConcurrentLogging() {
        // Bug #34 Verification
        let service = AuditService.shared
        let iterations = 100
        let expectation = XCTestExpectation(description: "Concurrent logging")
        expectation.expectedFulfillmentCount = iterations
        
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            service.logSuccess(
                operation: .encrypt,
                inputFile: "file_\(i).pdf",
                parameters: ["thread": "\(Thread.current)"]
            )
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
        
        // Allow async queue to drain
        let drainExpectation = XCTestExpectation(description: "Drain queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertEqual(service.sessionEvents.count, iterations, "Should capture all events without race condition")
            drainExpectation.fulfill()
        }
        wait(for: [drainExpectation], timeout: 2.0)
    }
    
    func testAppendOnlyIntegrity() {
        // Verify that logs are appended and not overwritten
        let service = AuditService.shared
        service.logSuccess(operation: .encrypt, inputFile: "1.pdf")
        service.logSuccess(operation: .encrypt, inputFile: "2.pdf")
        
        let drainExpectation = XCTestExpectation(description: "Drain queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(service.sessionEvents.count, 2)
            XCTAssertEqual(service.sessionEvents[0].inputFile, "1.pdf")
            XCTAssertEqual(service.sessionEvents[1].inputFile, "2.pdf")
            drainExpectation.fulfill()
        }
        wait(for: [drainExpectation], timeout: 2.0)
    }
}
