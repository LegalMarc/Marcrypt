import XCTest
import Foundation
@testable import MarcryptCore

/// Regression guard: audit logging writes NOTHING to disk when PersistentAuditEnabled is off.
///
/// This test confirms the privacy posture: with the default setting (key absent / false),
/// calling AuditService.log(event:) must not create or modify any on-disk audit.jsonl file.
/// Confidential document filenames must never reach durable storage unless the user explicitly
/// opts in via the PersistentAuditEnabled toggle in Settings.
final class TestAuditServicePrivacyPosture: XCTestCase {

    // MARK: - Setup / Teardown

    private var testDefaults: UserDefaults!
    private var testAuditFileURL: URL!

    override func setUpWithError() throws {
        // Use an isolated UserDefaults suite to avoid touching the real app defaults.
        let suiteName = "com.marcrypt.test.audit-privacy-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(testDefaults, "Test UserDefaults suite must be created")

        // Confirm the key is absent (default state).
        testDefaults.removeObject(forKey: "PersistentAuditEnabled")
        XCTAssertFalse(testDefaults.bool(forKey: "PersistentAuditEnabled"),
                       "PersistentAuditEnabled must default to false")

        // Compute the same audit file path that AuditService uses.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        testAuditFileURL = appSupport.appendingPathComponent("Marcrypt/audit.jsonl")
    }

    override func tearDownWithError() throws {
        testDefaults = nil
    }

    // MARK: - Privacy posture test

    /// With PersistentAuditEnabled absent/false, log(event:) must not write audit.jsonl to disk.
    ///
    /// Strategy:
    ///   1. Remove any pre-existing audit.jsonl to get a clean baseline.
    ///   2. Log several events through AuditService.shared (which reads UserDefaults.standard —
    ///      we cannot inject a custom defaults without subclassing, so we use the shared instance
    ///      and rely on the real key being false in the test environment).
    ///   3. Wait for AuditService's serial dispatch queue to drain.
    ///   4. Assert audit.jsonl does NOT exist (or has not been created/modified).
    func testAuditService_DefaultsOff_WritesNothingToDisk() throws {
        // Confirm the real UserDefaults.standard has this key false (test environment default).
        // If the key is true in the test environment, skip rather than produce a false failure.
        let persistEnabled = UserDefaults.standard.bool(forKey: "PersistentAuditEnabled")
        guard !persistEnabled else {
            throw XCTSkip("PersistentAuditEnabled is ON in this test environment — skipping privacy-posture test. Disable it in Settings before re-running.")
        }

        // Remove stale audit file so we have a clean before/after comparison.
        let fileManager = FileManager.default
        let preExistingAuditFile = testAuditFileURL!

        // Record modification date before the test (nil if file doesn't exist yet).
        let mDateBefore = (try? fileManager.attributesOfItem(atPath: preExistingAuditFile.path))?[.modificationDate] as? Date

        // Log several events that include "confidential" filenames.
        let service = AuditService.shared
        service.clearSessionEvents()

        service.logSuccess(operation: .encrypt, inputFile: "confidential-sample.pdf",
                           outputFile: "confidential-sample_encrypted.pdf")
        service.logSuccess(operation: .watermark, inputFile: "Client_Agreement.docx")
        service.logFailure(operation: .decrypt, inputFile: "ConfidentialEmployeeData.pdf",
                           reason: "Wrong password")

        // Drain AuditService's internal dispatch queue (it is async/utility qos).
        // We give it a full second — more than enough for any realistic queue drain.
        let drainExpectation = expectation(description: "AuditService queue drain")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            drainExpectation.fulfill()
        }
        wait(for: [drainExpectation], timeout: 3.0)

        // Assert audit.jsonl was NOT created or modified.
        let mDateAfter = (try? fileManager.attributesOfItem(atPath: preExistingAuditFile.path))?[.modificationDate] as? Date

        if mDateBefore == nil {
            // File did not exist before the test — it must still not exist.
            XCTAssertFalse(
                fileManager.fileExists(atPath: preExistingAuditFile.path),
                "audit.jsonl must NOT be created when PersistentAuditEnabled is false. " +
                "Found at: \(preExistingAuditFile.path)"
            )
        } else {
            // File existed before (from a prior session with audit enabled).
            // It must not have been modified — its modification date must be unchanged.
            XCTAssertEqual(
                mDateAfter, mDateBefore,
                "audit.jsonl must NOT be modified when PersistentAuditEnabled is false. " +
                "The file was touched during this test run."
            )
        }

        // Sanity: events ARE captured in-memory (in-memory cache is fine — it's not durable).
        let sessionEvents = service.sessionEvents
        XCTAssertGreaterThanOrEqual(sessionEvents.count, 3,
            "Events should be captured in-memory even when disk persistence is off")
    }
}
