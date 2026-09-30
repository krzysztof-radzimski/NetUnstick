import XCTest

/// Opt-in live harness against the already running production app. Each step is selected
/// with TEST_RUNNER_NETUNSTICK_LIVE_ACTION=unregister|register|repair|diagnose|device and drives the
/// real UI, helper registration and launchd daemon on this host. Nothing runs without the variable.
final class LiveRepairUITests: XCTestCase {
    private var action: String { ProcessInfo.processInfo.environment["NETUNSTICK_LIVE_ACTION"] ?? "" }

    /// The installed copy in ~/Applications is the one whose daemon launchd validates; a bundle
    /// identifier alone would resolve to the test build inside DerivedData under Documents,
    /// whose daemon macOS refuses with a launch constraint violation.
    private func attach() throws -> XCUIApplication {
        // The runner is sandboxed, so NSHomeDirectory() names its container; use the account home.
        let home = ProcessInfo.processInfo.environment["NETUNSTICK_APP_PATH"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir)).appendingPathComponent("Applications/NetUnstick.app")
        let installed = home
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path), "Install the signed build in ~/Applications first: \(installed.path)")
        let app = XCUIApplication(url: installed)
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "The installed app must be running")
        return app
    }

    private func helperStatus(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["nav.settings"].click()
        let status = app.descendants(matching: .any)["settings.helper"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        return status
    }

    private func text(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }

    func testLiveUnregisterHelper() throws {
        guard action == "unregister" else { throw XCTSkip("Opt-in live step") }
        let app = try attach()
        let status = helperStatus(app)
        print("NETUNSTICK_LIVE: helper before unregister: \(text(status))")
        XCTAssertTrue(app.buttons["helper.unregister"].waitForExistence(timeout: 3), "Unregister control expected: \(text(status))")
        app.buttons["helper.unregister"].click()
        let gone = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Niedostępny", "Niedostępny")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: status)], timeout: 20), .completed)
        print("NETUNSTICK_LIVE: helper after unregister: \(text(status))")
    }

    func testLiveRegisterHelper() throws {
        guard action == "register" else { throw XCTSkip("Opt-in live step") }
        let app = try attach()
        let status = helperStatus(app)
        print("NETUNSTICK_LIVE: helper before register: \(text(status))")
        if app.buttons["helper.register"].waitForExistence(timeout: 3) { app.buttons["helper.register"].click() }
        let available = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Dostępny", "Dostępny")
        let ready = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: status)], timeout: 20)
        print("NETUNSTICK_LIVE: helper after register: \(text(status))")
        XCTAssertEqual(ready, .completed, "Helper must be available; status: \(text(status))")
    }

    /// Runs one diagnosis in the installed app and prints the headline state, result and next step.
    func testLiveDiagnosis() throws {
        guard action == "diagnose" else { throw XCTSkip("Opt-in live step") }
        let app = try attach()
        app.descendants(matching: .any)["nav.status"].click()
        let start = app.buttons["diagnosis.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        // The result text carries the running marker first and the verdict afterwards.
        let result = app.staticTexts["dashboard.result"]
        let running = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Trwa diagnostyka", "Trwa diagnostyka")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: running, object: result)], timeout: 5)
        let finished = NSPredicate(format: "NOT (value CONTAINS %@) AND NOT (label CONTAINS %@)", "Trwa diagnostyka", "Trwa diagnostyka")
        let outcome = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: result)], timeout: 120)
        let state = text(app.descendants(matching: .any)["dashboard.state"])
        let verdict = text(result)
        let next = text(app.staticTexts["dashboard.nextStep"])
        print("NETUNSTICK_LIVE: state: \(state) | result: \(verdict) | next: \(next)")
        XCTAssertEqual(outcome, .completed, "Diagnosis must finish; last text: \(verdict)")
        XCTAssertFalse(verdict.isEmpty)
    }

    /// Runs the device test in the installed app for NETUNSTICK_DEVICE=host:port; prints outcome texts only.
    func testLiveDeviceTest() throws {
        guard action == "device" else { throw XCTSkip("Opt-in live step") }
        let target = ProcessInfo.processInfo.environment["NETUNSTICK_DEVICE"] ?? ""
        let parts = target.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return XCTFail("Set NETUNSTICK_DEVICE=host:port") }
        let app = try attach()
        app.descendants(matching: .any)["nav.status"].click()
        let field = app.textFields["device.host"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let dashboardScroll = app.scrollViews.element(boundBy: 1)
        for _ in 0..<3 where !field.isHittable { dashboardScroll.swipeUp() }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(parts[0])
        let picker = app.popUpButtons["device.port"]
        if picker.waitForExistence(timeout: 2), !text(picker).contains(parts[1]) {
            picker.click()
            let item = app.menuItems.containing(NSPredicate(format: "title CONTAINS %@", parts[1])).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Port \(parts[1]) must be offered by the picker")
            item.click()
        }
        let run = app.buttons["device.test"]
        run.click()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: run)], timeout: 2)
        let finished = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: run)], timeout: 30)
        XCTAssertEqual(finished, .completed, "The device test must finish")
        let outcomeElement = app.descendants(matching: .any)["device.outcome"]
        let outcome = text(outcomeElement).isEmpty ? outcomeElement.staticTexts.firstMatch.label : text(outcomeElement)
        let result = text(app.staticTexts["device.result"])
        let detail = text(app.staticTexts["device.detail"])
        print("NETUNSTICK_LIVE: device outcome: \(outcome) | result: \(result) | detail: \(detail)")
        XCTAssertFalse(detail.isEmpty)
    }

    func testLiveStaleTunnelRouteRepair() throws {
        guard action == "repair" else { throw XCTSkip("Opt-in live step") }
        let app = try attach()
        let status = helperStatus(app)
        XCTAssertTrue(text(status).contains("Dostępny"), "Helper must be available before a live repair: \(text(status))")
        app.descendants(matching: .any)["nav.status"].click()
        let start = app.buttons["diagnosis.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        let open = app.buttons["repair.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 60), "Diagnosis must offer the stale-route candidate")
        let dashboardScroll = app.scrollViews.element(boundBy: 1)
        for _ in 0..<3 where !open.isHittable { dashboardScroll.swipeUp() }
        open.click()
        let confirm = app.buttons["repair.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "The in-window confirmation must appear")
        for _ in 0..<3 where !confirm.isHittable { dashboardScroll.swipeUp() }
        confirm.click()
        let result = app.staticTexts["dashboard.result"]
        let finished = NSPredicate(format: "value CONTAINS %@ OR value CONTAINS %@", "Naprawiono", "Naprawa:")
        let outcome = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: result)], timeout: 240)
        let verdict = text(result)
        let next = (app.staticTexts["dashboard.nextStep"].value as? String) ?? ""
        print("NETUNSTICK_LIVE: verdict: \(verdict) | next: \(next)")
        XCTAssertEqual(outcome, .completed, "The repair must finish with a verdict; last text: \(verdict)")
        XCTAssertTrue(verdict.contains("Naprawiono"), "Repair verdict: \(verdict)")
    }
}
