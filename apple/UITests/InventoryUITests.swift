import XCTest

/// Adds one uniquely named fixture and deliberately leaves all existing inventory intact.
final class InventoryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testInventoryMetadataAndMinimumStockSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--module", "inventory"]
        app.launch()
        let addItem = app.buttons["Add item"]
        XCTAssertTrue(addItem.waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["Inventory"].exists, app.alerts["Inventory"].debugDescription)
        XCTAssertTrue(addItem.isEnabled, "Inventory must load safely before creating a fixture")
        addItem.tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5))

        let token = String(UUID().uuidString.prefix(8))
        let name = "Inventory persistence \(token)"
        let tag = "ui-\(token.lowercased())"
        let serial = "SN-\(token)"
        enter(name, in: "Name", app: app)
        enter("UI fixture cabinet", in: "Location", app: app)
        enter("2", in: "Quantity", app: app)
        enter("3", in: "Minimum stock (optional)", app: app)
        enter("\(tag), preparedness", in: "Tags, separated by commas", app: app)
        enter("Offline Devices", in: "Manufacturer", app: app)
        enter("M1 fixture", in: "Model", app: app)
        enter(serial, in: "Serial number", app: app)
        app.navigationBars["Inventory item"].buttons["Save"].tap()

        searchFor(name, app: app)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["At or below minimum stock"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(addItem.waitForExistence(timeout: 20))
        searchFor(name, app: app)
        let saved = app.staticTexts[name]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["At or below minimum stock"].waitForExistence(timeout: 5))
        saved.tap()

        assertValue(name, field: "Name", app: app)
        assertValue("UI fixture cabinet", field: "Location", app: app)
        assertValue("2", field: "Quantity", app: app)
        assertValue("3", field: "Minimum stock (optional)", app: app)
        assertValue("\(tag), preparedness", field: "Tags, separated by commas", app: app)
        assertValue("Offline Devices", field: "Manufacturer", app: app)
        assertValue("M1 fixture", field: "Model", app: app)
        assertValue(serial, field: "Serial number", app: app)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Persisted native inventory metadata"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["Inventory item"].buttons["Cancel"].tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let form = app.collectionViews["inventory.editor.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<12 {
            let frame = form.frame
            let top = frame.minY + 85
            let keyboard = app.keyboards.firstMatch
            let bottom = min(frame.maxY - 45, keyboard.exists ? keyboard.frame.minY - 30 : frame.maxY - 45)
            if element.exists && element.isHittable && element.frame.midY > top && element.frame.midY < bottom { return }
            // Short drags avoid flinging a field behind the sheet's navigation bar.
            let down = element.exists && element.frame.midY <= top
            let center = (top + bottom) / 2
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: center + (down ? -55 : 55)))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: center + (down ? 55 : -55)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected inventory field to be reachable", file: file, line: line)
    }

    @MainActor
    private func enter(_ text: String, in label: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[label]
        reveal(field, app: app, file: file, line: line)
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty && existing != label { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, file: file, line: line)
    }

    @MainActor
    private func assertValue(_ expected: String, field label: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[label]
        reveal(field, app: app, file: file, line: line)
        XCTAssertEqual(field.value as? String, expected, file: file, line: line)
    }

    @MainActor
    private func searchFor(_ name: String, app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        for _ in 0..<4 {
            if search.exists && search.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(search.exists && search.isHittable)
        search.tap()
        search.typeText(name)
    }
}
