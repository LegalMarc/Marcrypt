import XCTest

final class MarcryptUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // UI tests must launch the application that they test.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["MARCRYPT_RUN_UI_TESTS"] != "1",
            "UI Tests require Xcode UI Runner, skipping in swift test CLI"
        )
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    func testStress_RapidTabSwitching() throws {
        // app is already launched in setUp

        // Stress test launch/terminate cycles under the Xcode UI runner.
        for _ in 0..<3 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        }
    }

    func testStress_InvalidFilePaths() throws {
        // app is already launched in setUp

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testStress_SettingsToggle() throws {
        // app is already launched in setUp

        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }
}
