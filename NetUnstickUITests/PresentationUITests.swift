import XCTest

final class PresentationUITests: XCTestCase {
    private func ensureWindow(_ app: XCUIApplication) {
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "A standard window must open")
        }
    }

    private func launch(_ scenario: String, appearance: String? = nil, contrast: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scenario=\(scenario)"]
        if let appearance { app.launchArguments += [appearance == "Dark" ? "--ui-dark" : "--ui-light"] }
        if contrast { app.launchArguments += ["--ui-light", "--ui-contrast"] }
        app.launch()
        ensureWindow(app)
        return app
    }

    private func launchIntegration(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--integration-scenario=\(scenario)"]
        app.launch()
        ensureWindow(app)
        return app
    }

    func testRealCompositionWithFakeSystemBoundary() {
        let healthy = launchIntegration("healthy")
        healthy.buttons["diagnosis.start"].click()
        XCTAssertTrue(healthy.buttons["check.unicast_dns_resolution"].waitForExistence(timeout: 10))
        XCTAssertFalse(healthy.buttons["repair.open"].exists)
        healthy.terminate()

        for (scenario, verified) in [("verified", true), ("unresolved", false)] {
            let app = launchIntegration(scenario)
            app.buttons["diagnosis.start"].click()
            let privileged = app.buttons["repair.open"]
            XCTAssertTrue(privileged.waitForExistence(timeout: 10))
            privileged.click()
            XCTAssertTrue(app.buttons["repair.confirm"].waitForExistence(timeout: 5))
            app.buttons["repair.confirm"].click()
            let result = app.staticTexts["dashboard.result"]
            let fragment = verified ? "Naprawiono" : "recheck_failed"
            let predicate = NSPredicate(format: "value CONTAINS %@", fragment)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: result)], timeout: 10), .completed)
            app.buttons["report.preview.open"].click()
            let preview = app.descendants(matching: .any)["report.preview.text"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            let report = preview.staticTexts.firstMatch.value as? String ?? ""
            XCTAssertTrue(report.contains("NetUnstick session report"))
            XCTAssertFalse(report.contains("secret.corp"))
            XCTAssertFalse(report.contains("192.0.2.53"))
            app.buttons["report.cancel"].click()
            app.terminate()
        }

        for scenario in ["vpn-active", "vpn-unknown"] {
            let app = launchIntegration(scenario)
            app.buttons["diagnosis.start"].click()
            XCTAssertTrue(app.buttons["check.unicast_dns_resolution"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["repair.open"].exists)
            app.terminate()
        }
    }

    func testNavigationDetailsRepairAndReport() {
        let app = launch("dns-residue")
        XCTAssertTrue(app.buttons["diagnosis.start"].waitForExistence(timeout: 10))
        let state = app.descendants(matching: .any)["dashboard.state"]
        XCTAssertTrue(state.exists)
        let dns = app.buttons["check.mock.dns"]
        XCTAssertTrue(dns.waitForExistence(timeout: 10))
        let dashboardScroll = app.scrollViews.element(boundBy: 1)
        for _ in 0..<3 where !dns.isHittable { dashboardScroll.swipeUp() }
        XCTAssertTrue(dns.isHittable)
        dns.click()
        let technicalDetail = app.staticTexts["check.mock.dns.detail"]
        XCTAssertTrue(technicalDetail.waitForExistence(timeout: 5))
        let detailText = technicalDetail.value as? String ?? technicalDetail.label
        XCTAssertFalse(detailText.contains("secret.corp"))
        XCTAssertFalse(detailText.contains("192.0.2.53"))
        app.buttons["repair.open"].click()
        XCTAssertTrue(app.buttons["repair.confirm"].waitForExistence(timeout: 5))
        app.buttons["repair.cancel"].click()
        app.descendants(matching: .any)["nav.activity"].click()
        XCTAssertTrue(app.buttons["report.preview.open"].exists)
        app.buttons["report.preview.open"].click()
        XCTAssertTrue(app.buttons["report.save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["report.preview.text"].exists)
        app.buttons["report.save"].click()
        let fileName = app.textFields.matching(NSPredicate(format: "value BEGINSWITH %@", "NetUnstick-report")).firstMatch
        XCTAssertTrue(fileName.waitForExistence(timeout: 5), "The standard save dialog must open after the preview")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(fileName.waitForNonExistence(timeout: 5), "Cancelling the save dialog must close it without saving")
    }

    func testCancelAndKeyboardShortcut() {
        let app = launch("operation-progress")
        let cancel = app.buttons["diagnosis.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertFalse(app.buttons["diagnosis.cancel"].exists)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.buttons["diagnosis.cancel"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["diagnosis.cancel"].exists)
    }

    func testConfirmedRepairRequiresSuccessfulRecheck() {
        let success = launch("repair-success")
        XCTAssertTrue(success.buttons["repair.open"].waitForExistence(timeout: 10))
        success.buttons["repair.open"].click()
        XCTAssertTrue(success.buttons["repair.confirm"].waitForExistence(timeout: 5))
        success.buttons["repair.confirm"].click()
        let verified = success.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Naprawiono")).firstMatch
        XCTAssertTrue(verified.waitForExistence(timeout: 5))
        XCTAssertTrue((success.staticTexts["dashboard.result"].value as? String)?.contains("Naprawiono") == true)
        success.terminate()

        let failed = launch("repair-failure")
        XCTAssertTrue(failed.buttons["repair.open"].waitForExistence(timeout: 10))
        failed.buttons["repair.open"].click()
        failed.buttons["repair.confirm"].click()
        let failure = failed.staticTexts["dashboard.result"]
        let failedPredicate = NSPredicate(format: "value CONTAINS %@", "recheck_failed")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: failedPredicate, object: failure)], timeout: 5), .completed)
        XCTAssertFalse(failed.staticTexts["repair.phase"].exists, "No raw phase name stays on screen after a repair")
        XCTAssertFalse((failed.staticTexts["dashboard.result"].value as? String)?.contains("Naprawiono") == true)
    }

    func testActiveAndUnknownVPNExplainBlockedChange() {
        for scenario in ["vpn-active", "vpn-unknown"] {
            let app = launch(scenario)
            XCTAssertTrue(app.staticTexts["dashboard.vpn"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["repair.open"].exists)
            app.terminate()
        }
    }

    func testHelperApprovalAndLimitedEnvironmentRemainUsable() {
        let app = launch("helper-approval")
        app.descendants(matching: .any)["nav.settings"].click()
        XCTAssertTrue(app.buttons["helper.register"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["helper.settings"].exists)
        app.descendants(matching: .any)["nav.status"].click()
        XCTAssertTrue(app.buttons["diagnosis.start"].exists)
        app.terminate()

        let timedOut = launch("timeout")
        let timeoutResult = timedOut.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR value CONTAINS %@", "czasie", "time")).firstMatch
        XCTAssertTrue(timeoutResult.waitForExistence(timeout: 10))
    }

    func testDeniedBonjourAndMissingReceiverAreEnvironmentOutcomes() {
        let denied = launch("bonjour-denied")
        let permission = denied.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR value CONTAINS %@", "odmówił", "denied")).firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        XCTAssertFalse(denied.buttons["repair.open"].exists)
        denied.terminate()

        let absent = launch("no-receiver")
        let bonjour = absent.buttons["check.mock.bonjour"]
        XCTAssertTrue(bonjour.waitForExistence(timeout: 10))
        XCTAssertTrue(bonjour.label.contains("niejednoznaczny") || bonjour.label.contains("Not conclusive"))
        XCTAssertFalse(absent.buttons["repair.open"].exists)
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
        app.terminate()

        let variant = XCUIApplication()
        variant.launchArguments = ["--scenario=dns-residue", "--ui-large-text"]
        variant.launch()
        ensureWindow(variant)
        XCTAssertTrue(variant.descendants(matching: .any)["dashboard.state"].waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: variant.screenshot())
        capture.name = "dns-residue-large-text"
        capture.lifetime = .keepAlways
        add(capture)
        variant.terminate()

        let reduced = XCUIApplication()
        reduced.launchArguments = ["--scenario=dns-residue", "--ui-reduce-motion"]
        reduced.launch()
        ensureWindow(reduced)
        XCTAssertTrue(reduced.descendants(matching: .any)["dashboard.state"].waitForExistence(timeout: 10))
        let reducedCapture = XCTAttachment(screenshot: reduced.screenshot())
        reducedCapture.name = "dns-residue-reduce-motion"
        reducedCapture.lifetime = .keepAlways
        add(reducedCapture)
        reduced.terminate()
    }
}
