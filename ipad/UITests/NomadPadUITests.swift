import XCTest

final class NomadPadUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBackupScreenCreatesLocalFolder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "settings"]
        app.launch()
        let link = app.buttons["Backup and restore"]
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        if !link.isHittable { app.swipeUp() }
        link.tap()
        let create = app.buttons["Create backup folder"]
        for _ in 0..<12 {
            if create.exists && create.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(create.isHittable)
        create.tap()
        let share = app.buttons["Share or save complete backup folder"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
    }

    @MainActor
    func testConversationRenameSurvivesColdLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "assistant"]
        app.launch()
        let newChat = app.buttons["New conversation"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
        app.buttons["Conversations"].tap()
        let rename = app.buttons["Rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        rename.tap()
        let title = app.alerts.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let name = "Saved conversation \(UUID().uuidString.prefix(8))"
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "New conversation".count))
        title.typeText(name)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 20))
        app.buttons["Conversations"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNoteSurvivesColdLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "notes"]
        app.launch()
        let create = app.buttons["New note"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        create.tap()
        let name = "Offline persistence test \(UUID().uuidString.prefix(8))"
        let title = app.textFields["Note title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText(name)
        let body = app.textViews["Note text"]
        body.tap(); body.typeText("A local note that must survive restarting the app.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 15))
    }

    /// Preserve the simulator container: Notes and Media must share its existing directory spelling.
    @MainActor
    func testNotesThenMediaStorageRemainUsableAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "notes"]
        app.launch()
        let createNote = app.buttons["New note"]
        XCTAssertTrue(createNote.waitForExistence(timeout: 20))
        XCTAssertTrue(createNote.isEnabled, "Notes must load its existing storage before opening Media")
        XCTAssertFalse(app.alerts["Notes error"].exists, app.alerts["Notes error"].debugDescription)
        createNote.tap()
        XCTAssertTrue(app.textFields["Note title"].waitForExistence(timeout: 5))
        app.navigationBars["New note"].buttons["Cancel"].tap()
        app.terminate()

        // Use the existing module launch route so this works with either iPad sidebar layout.
        // Each launch uses the same application container; no fixtures or user data are removed.
        app.launchArguments = ["--module", "media"]
        for attempt in 1...2 {
            app.launch()
            let importMedia = app.buttons["Import media"]
            XCTAssertTrue(importMedia.waitForExistence(timeout: 20))
            XCTAssertFalse(app.alerts["Media library"].exists, app.alerts["Media library"].debugDescription)
            XCTAssertFalse(app.buttons["Reload preserved media library"].exists, "Media startup must not fall back to preserved-data recovery")
            XCTAssertTrue(importMedia.isEnabled, "The production Media store must be writable after Notes initialized storage")
            let createPlaylist = app.buttons["New playlist"]
            XCTAssertTrue(createPlaylist.waitForExistence(timeout: 5))
            XCTAssertTrue(createPlaylist.isEnabled)
            createPlaylist.tap()
            XCTAssertTrue(app.textFields["Playlist name"].waitForExistence(timeout: 5))
            app.navigationBars["Edit playlist"].buttons["Cancel"].tap()
            XCTAssertTrue(importMedia.waitForExistence(timeout: 5))
            XCTAssertTrue(importMedia.isEnabled)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Usable Media library after Notes, launch \(attempt)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    @MainActor
    func testNativeTextToolProducesExpectedOutput() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "tools"]
        app.launch()
        let input = app.textViews["Input text"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap(); input.typeText("NOMAD offline")
        let run = app.buttons["Run Base64 encode"]
        if !run.isHittable { app.swipeUp() }
        run.tap()
        let output = app.staticTexts["Tk9NQUQgb2ZmbGluZQ=="]
        if !output.isHittable { app.swipeUp() }
        XCTAssertTrue(output.waitForExistence(timeout: 5))
    }

    @MainActor
    func testDashboardAndModuleCatalogAreReachable() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["A world of knowledge.\nAlways within reach."].waitForExistence(timeout: 20))
        app.buttons["All modules"].tap()
        XCTAssertTrue(app.staticTexts["Choose your tools and content."].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "NOMAD native module catalog"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testBundledContentCatalogCanSearchWithoutRefreshing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "downloads"]
        app.launch()
        let catalog = app.buttons["Browse Wikipedia and map regions"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 20))
        catalog.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Hawaii")
        XCTAssertTrue(app.staticTexts["Hawaii"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Quick Reference"].exists)
    }

    @MainActor
    func testFileFolderCanBeRenamedAndPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "files"]
        app.launch()
        let create = app.buttons["New folder"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        create.tap()
        let name = "Local folder \(UUID().uuidString.prefix(8))"
        let field = app.alerts.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.alerts.buttons["Save"].tap()
        let folder = app.staticTexts[name]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.press(forDuration: 1)
        app.buttons["Rename"].tap()
        let renamed = name + " renamed"
        let rename = app.alerts.textFields["Name"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: name.count))
        rename.typeText(renamed)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 15))
    }
}
