//
//  VideoConverterUITests.swift
//  video-converterUITests
//

import XCTest

final class VideoConverterUITests: XCTestCase {
    private let sample = "h264-aac-movtext.mp4"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Empty window

    @MainActor
    func testShowsEmptyStateOnLaunch() throws {
        let app = try launch()
        XCTAssertTrue(element("emptyState", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Videos"].exists)
        XCTAssertTrue(app.staticTexts["No folder selected"].exists)
        XCTAssertFalse(app.buttons["convertButton"].isEnabled, "Nothing to convert yet")
        XCTAssertFalse(app.buttons["clearFinishedButton"].isEnabled)
        XCTAssertTrue(app.buttons["addVideosButton"].isEnabled)
    }

    @MainActor
    func testFormatMenuListsEveryFormat() throws {
        let app = try launch()
        let picker = app.popUpButtons["formatPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let titles = [
            "MP4 (H.264)", "MP4 (HEVC / H.265)", "MKV (H.264)", "MOV (H.264)",
            "MOV (HEVC / H.265)", "MOV (ProRes 422)", "M4V (H.264)", "M4A (Audio only)"
        ]
        for title in titles {
            XCTAssertTrue(app.menuItems[title].exists, "Missing \(title)")
        }
        app.menuItems["MKV (H.264)"].click()
        XCTAssertEqual(picker.value as? String, "MKV (H.264)")
    }

    @MainActor
    func testSubtitleMenuListsEveryMode() throws {
        let app = try launch()
        let picker = app.popUpButtons["subtitlesPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Burn in (always visible)")
        picker.click()
        for title in ["Burn in (always visible)", "Keep as track (enabled by default)", "Remove subtitles"] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing \(title)")
        }
        app.menuItems["Remove subtitles"].click()
        XCTAssertEqual(picker.value as? String, "Remove subtitles")
    }

    // MARK: Queue

    @MainActor
    func testQueuedFileShowsItsEmbeddedSubtitles() throws {
        let app = try launch(queueing: [sample])
        XCTAssertTrue(app.staticTexts[sample].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 embedded subtitle track"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Waiting"].exists)
        XCTAssertFalse(element("emptyState", in: app).exists)
        XCTAssertFalse(app.buttons["convertButton"].isEnabled, "No output folder chosen")
    }

    @MainActor
    func testRemovingTheOnlyFileShowsTheEmptyState() throws {
        let app = try launch(queueing: [sample])
        let menu = element("rowMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems["Remove from List"].click()
        XCTAssertTrue(element("emptyState", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[sample].exists)
    }

    // MARK: Converting

    @MainActor
    func testConvertAllFinishesAndClearFinishedEmptiesTheList() throws {
        let app = try launch(queueing: [sample], withOutputFolder: true)
        let convert = app.buttons["convertButton"]
        XCTAssertTrue(convert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No folder selected"].exists)
        XCTAssertTrue(convert.isEnabled)

        convert.click()
        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 60), "The conversion didn't finish")
        // Everything is converted, so there's nothing left to start.
        XCTAssertTrue(convert.waitForExistence(timeout: 5))
        XCTAssertFalse(convert.isEnabled)

        let clearFinished = app.buttons["clearFinishedButton"]
        XCTAssertTrue(clearFinished.isEnabled)
        clearFinished.click()
        XCTAssertTrue(element("emptyState", in: app).waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    /// Launches the app with `files` from the test bundle already queued. The sandboxed app can't
    /// read this bundle, so the file contents are passed in the environment (see `UITestingSupport`).
    @MainActor
    private func launch(queueing files: [String] = [], withOutputFolder: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        let bundle = Bundle(for: Self.self)
        let entries = try files.map { name in
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: nil), "Missing fixture \(name)")
            return "\(name):\(try Data(contentsOf: url).base64EncodedString())"
        }
        app.launchEnvironment["UITEST_FILES"] = entries.joined(separator: ";")
        if withOutputFolder {
            app.launchEnvironment["UITEST_OUTPUT"] = "1"
        }
        app.launch()
        return app
    }

    /// Finds an element by accessibility identifier, whatever its type.
    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
