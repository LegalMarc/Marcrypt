import XCTest
import Foundation
@testable import MarcryptCore

/// Unit Tests for Password Candidate Loading
final class PasswordLoaderTests: XCTestCase {
    
    // MARK: - U7: Password Candidate Loader
    
    func testPasswordCandidateLoaderReturnsDefaults() {
        let candidates = PasswordGuessingService.shared.loadCandidates()
        
        // Should have at least the default passwords
        XCTAssertFalse(candidates.isEmpty, "Should return at least default passwords")
        
        // Check for known defaults
        let expectedDefaults = ["123456", "password", "12345678", "qwerty"]
        for expected in expectedDefaults {
            XCTAssertTrue(candidates.contains(expected), 
                         "Should contain default password: \(expected)")
        }
    }
    
    func testPasswordCandidatesAreUnique() {
        let candidates = PasswordGuessingService.shared.loadCandidates()
        let uniqueSet = Set(candidates)
        
        XCTAssertEqual(candidates.count, uniqueSet.count, 
                       "Password list should have no duplicates")
    }
}
