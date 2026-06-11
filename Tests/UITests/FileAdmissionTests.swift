import XCTest
import MarcryptCore
@testable import Marcrypt

@MainActor
final class FileAdmissionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marcrypt-file-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUserSelectedSupportedFileGetsInMemorySecurityScopedBookmark() throws {
        let fileURL = tempDir.appendingPathComponent("selected.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: fileURL)

        do {
            _ = try FileItem.makeSecurityScopedBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test host: \(error.localizedDescription)")
        }

        let viewModel = FileViewModel()
        XCTAssertEqual(viewModel.addUserSelected(urls: [fileURL]), 1)

        let item = try XCTUnwrap(viewModel.items.first)
        XCTAssertEqual(item.url, fileURL)
        XCTAssertNotNil(item.securityScopedBookmarkData)
        XCTAssertNil(item.managedSourceRoot)
    }

    func testPreBookmarkedDropInputIsAcceptedWithoutCreatingPersistentState() throws {
        let fileURL = tempDir.appendingPathComponent("dropped.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: fileURL)

        let bookmarkData: Data
        do {
            bookmarkData = try FileItem.makeSecurityScopedBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test host: \(error.localizedDescription)")
        }

        let viewModel = FileViewModel()
        let input = FileViewModel.UserSelectedInput(url: fileURL, bookmarkData: bookmarkData)
        XCTAssertEqual(viewModel.addUserSelected(inputs: [input]), 1)

        let item = try XCTUnwrap(viewModel.items.first)
        XCTAssertEqual(item.url, fileURL)
        XCTAssertEqual(item.securityScopedBookmarkData, bookmarkData)
        XCTAssertNil(item.managedSourceRoot)
    }

    func testPromisedFileAdmissionDoesNotCreateExternalBookmark() throws {
        let stagingRoot = tempDir.appendingPathComponent("promised-root")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let promisedURL = stagingRoot.appendingPathComponent("promised.docx")
        try Data("placeholder".utf8).write(to: promisedURL)

        let viewModel = FileViewModel()
        XCTAssertEqual(viewModel.addPromised(urls: [promisedURL], managedSourceRoot: stagingRoot), 1)

        let item = try XCTUnwrap(viewModel.items.first)
        XCTAssertEqual(item.url, promisedURL)
        XCTAssertNil(item.securityScopedBookmarkData)
        XCTAssertEqual(item.managedSourceRoot, stagingRoot)
    }

    func testUnsupportedUserSelectedFileIsRejectedVisibly() throws {
        let fileURL = tempDir.appendingPathComponent("notes.txt")
        try Data("not supported".utf8).write(to: fileURL)

        do {
            _ = try FileItem.makeSecurityScopedBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test host: \(error.localizedDescription)")
        }

        let viewModel = FileViewModel()
        XCTAssertEqual(viewModel.addUserSelected(urls: [fileURL]), 0)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.showUnsupportedAlert)
        XCTAssertEqual(viewModel.unsupportedFiles, [fileURL])
    }

    func testFileItemDetectsDirectoryThroughSecurityScopedBookmark() throws {
        let folderURL = tempDir.appendingPathComponent("SelectedFolder")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let bookmarkData: Data
        do {
            bookmarkData = try FileItem.makeSecurityScopedBookmark(for: folderURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test host: \(error.localizedDescription)")
        }

        let item = FileItem(url: folderURL, securityScopedBookmarkData: bookmarkData)
        XCTAssertEqual(item.type, .folder)
    }
}
