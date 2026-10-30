import XCTest

/// Real system controls, running against an isolated empty DEBUG store.
final class NativeAppUITests: XCTestCase {
    private func launch(dark: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KCAL_UI_TESTING"] = "1"
        app.launchEnvironment["KCAL_UI_DARK"] = dark ? "1" : "0"
        app.launchEnvironment["KCAL_UI_LARGE_TEXT"] = largeText ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["饮食"].waitForExistence(timeout: 15))
        return app
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    func testSystemTabsAndNativeDateControls() {
        let app = launch()
        XCTAssertEqual(app.webViews.count, 0, "All visible pages must be SwiftUI")
        app.tabBars.buttons["健康"].tap()
        XCTAssertTrue(app.buttons["health-sync"].waitForExistence(timeout: 5))
        screenshot(app, "SwiftUI-health-light")
        reveal(app.buttons["health-sync"], in: app)
        app.buttons["health-sync"].tap()
        let start = app.descendants(matching: .any).matching(identifier: "health-sync-from").firstMatch
        let end = app.descendants(matching: .any).matching(identifier: "health-sync-through").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(end.exists)
        XCTAssertGreaterThan(start.frame.height, 0)
        XCTAssertGreaterThan(end.frame.height, 0)
        XCTAssertLessThanOrEqual(start.frame.maxY, end.frame.minY, "Date controls must occupy separate rows")
        XCTAssertTrue(app.buttons["health-sync-read"].exists)
        screenshot(app, "SwiftUI-health-sync-native-dates")
        // Request/error lifecycle is covered with a controlled HealthKit provider
        // in unit tests. UI tests never request the simulator's health database.
        app.buttons["关闭"].tap()
        app.tabBars.buttons["饮食"].tap()
        XCTAssertTrue(app.buttons["record-date"].exists)
    }

    func testManualFoodSavesAndRemainsAfterTabSwitch() {
        let app = launch()
        let add = app.buttons["add-food-breakfast"]
        reveal(add, in: app)
        add.tap()
        let manual = app.buttons["手动填写食物"]
        reveal(manual, in: app)
        manual.tap()
        XCTAssertTrue(app.textFields["food-name"].waitForExistence(timeout: 5))
        app.textFields["food-name"].tap()
        app.textFields["food-name"].typeText("Synthetic oats")
        for (label, value) in [("热量", "320"), ("蛋白质", "15"), ("脂肪", "8"), ("碳水", "45")] {
            let field = app.textFields[label]
            reveal(field, in: app)
            field.tap(); field.typeText(value)
        }
        let save = app.buttons["save-food"]
        reveal(save, in: app); save.tap()
        XCTAssertTrue(app.tabBars.buttons["健康"].waitForExistence(timeout: 5))
        app.tabBars.buttons["健康"].tap()
        app.tabBars.buttons["饮食"].tap()
        let food = app.descendants(matching: .any).matching(identifier: "food-row-breakfast-0").firstMatch
        reveal(food, in: app)
        XCTAssertTrue(food.exists)
        XCTAssertTrue(food.label.contains("Synthetic oats"))
        XCTAssertEqual(app.webViews.count, 0)
        screenshot(app, "SwiftUI-food-saved")
    }

    func testDarkAndAccessibilityNavigation() {
        let app = launch(dark: true, largeText: true)
        screenshot(app, "SwiftUI-diet-dark-accessibility")
        app.tabBars.buttons["健康"].tap()
        let sync = app.buttons["health-sync"]
        reveal(sync, in: app); sync.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "health-sync-from").firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "SwiftUI-sync-dark-accessibility")
        XCTAssertEqual(app.webViews.count, 0)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "Expected native control to be reachable by scrolling")
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
