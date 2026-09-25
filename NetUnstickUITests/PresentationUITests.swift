import XCTest

final class PresentationUITests: XCTestCase {
    private func launch(_ scenario: String, appearance: String? = nil, contrast: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scenario=\(scenario)"]
        if let appearance { app.launchArguments += [appearance == "Dark" ? "--ui-dark" : "--ui-light"] }
        if contrast { app.launchArguments += ["--ui-light", "--ui-contrast"] }
        app.launch()
        return app
    }

    func testNavigationDetailsRepairAndReport() {
        let app = launch("dns-residue")
        XCTAssertTrue(app.buttons["diagnosis.start"].waitForExistence(timeout: 10))
        let state = app.descendants(matching: .any)["dashboard.state"]
        XCTAssertTrue(state.exists)
        let dns = app.buttons["check.dns"]
        XCTAssertTrue(dns.waitForExistence(timeout: 10))
        let dashboardScroll = app.scrollViews.element(boundBy: 1)
        for _ in 0..<3 where !dns.isHittable { dashboardScroll.swipeUp() }
        XCTAssertTrue(dns.isHittable)
        dns.click()
        let technicalDetail = app.staticTexts["check.dns.detail"]
        XCTAssertTrue(technicalDetail.waitForExistence(timeout: 5))
        app.buttons["repair.open"].click()
        XCTAssertTrue(app.buttons["repair.confirm"].waitForExistence(timeout: 5))
        app.buttons["repair.cancel"].click()
        app.descendants(matching: .any)["nav.activity"].click()
        XCTAssertTrue(app.buttons["report.preview.open"].exists)
        app.buttons["report.preview.open"].click()
        XCTAssertTrue(app.buttons["report.save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["report.preview.text"].exists)
    }

    func testCancelAndKeyboardShortcut() {
        let app = launch("operation-progress")
        XCTAssertTrue(app.buttons["diagnosis.cancel"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["diagnosis.cancel"].exists)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.buttons["diagnosis.cancel"].waitForExistence(timeout: 5))
        app.buttons["diagnosis.cancel"].click()
    }

    func testKeyboardNavigationAndIdentifiers() {
        let app = launch("healthy")
        let status = app.descendants(matching: .any)["nav.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["report.preview.open"].waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["settings.helper"].waitForExistence(timeout: 5))
    }

    func testScreenshotMatrix() {
        for scenario in ["healthy", "dns-residue", "vpn-unknown", "operation-progress"] {
            for style in ["Aqua", "Dark"] {
                let app = launch(scenario, appearance: style)
                XCTAssertTrue(app.descendants(matching: .any)["dashboard.state"].waitForExistence(timeout: 10))
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(scenario)-\(style)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
        let app = launch("dns-residue", contrast: true)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.state"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "dns-residue-increased-contrast"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
