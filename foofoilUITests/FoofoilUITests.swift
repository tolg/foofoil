//
//  FoofoilUITests.swift
//  foofoilUITests
//
//  Created by tolg on 2026/7/6.
//

import XCTest

final class FoofoilUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testFullScreenShortcutEntersFullScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let windowedFrame = window.frame

        app.typeKey("f", modifierFlags: [.command, .control])
        let enteredFullScreen = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                window.exists && window.frame.width > windowedFrame.width + 100
            },
            object: nil
        )
        wait(for: [enteredFullScreen], timeout: 5)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
