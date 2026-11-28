import XCTest

/// UI tests on the made-up log. `-demo` loads `demo.json` from the app bundle (Debug only)
/// through `LogStore.loadDemo`, so nothing here touches the network or HealthKit.
/// `-now` freezes the clock. `-scriptedReminders` grants or denies notification permission
/// in the app and records the scheduled ids, so these tests never show a system alert.
final class DemoFlowsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHealthSyncPanelStaysOffOnDemoData() {
        let app = launch("log")
        let status = app.staticTexts["health.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertEqual(status.label, "Apple Health sync is off in demo mode.")

        let sync = app.buttons["health.sync"]
        let backfill = app.buttons["health.backfill"]
        XCTAssertTrue(sync.exists)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(sync.label, "Sync the last 30 days")
        XCTAssertTrue(backfill.exists)
        XCTAssertFalse(backfill.isEnabled)
        XCTAssertEqual(backfill.label, "Backfill history")
    }

    func testMissedDoseShowsOverdueAndCanBeSkipped() {
        let app = launch("meds", [
            "-now", "2026-11-30T08:00:00-06:00",
            "-scrollTo", "plan",
            "-scriptedReminders",
        ])
        let headline = app.staticTexts["dose.plan.next"]
        waitHittable(headline)
        XCTAssertTrue(headline.label.hasPrefix("Overdue"), headline.label)

        let when = app.staticTexts["dose.when"]
        XCTAssertTrue(when.waitForExistence(timeout: 8))
        XCTAssertTrue(when.label.contains("Overdue"), when.label)

        let remind = app.buttons["dose.remind"]
        waitHittable(remind)
        remind.tap()
        let scheduled = waitProbe(app, contains: "log.shot.2026-11-29.due.2026-11-30")
        let ids = Set(scheduled.split(separator: " ").map(String.init))
        XCTAssertTrue(ids.contains("log.shot.2026-11-29.due.2026-11-30"))
        XCTAssertFalse(ids.contains("log.shot.2026-11-29"))
        let remindGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 0"), object: remind)
        XCTAssertEqual(XCTWaiter().wait(for: [remindGone], timeout: 8), .completed)

        let skip = app.buttons["dose.skip"]
        waitHittable(skip)
        skip.tap()
        let message = app.staticTexts["form.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        XCTAssertEqual(message.label, "Skipped the planned dose.")
    }

    func testLocalRemindersScheduleWhenPermissionIsGranted() {
        let app = launch("log", [
            "-now", "2026-11-24T23:20:00-06:00",
            "-scrollTo", "reminders",
            "-scriptedReminders",
        ])
        let weigh = app.switches["reminder.weigh"]
        waitHittable(weigh)
        weigh.tap()
        var scheduled = waitProbe(app, contains: "log.weigh.2026-11-25")
        XCTAssertFalse(Set(scheduled.split(separator: " ").map(String.init)).contains("log.weigh.2026-11-24"))
        XCTAssertTrue(turnedOn(weigh))

        waitHittable(app.switches["reminder.checkin"]).tap()
        scheduled = waitProbe(app, contains: "log.checkin.2026-11-25")

        let shot = app.switches["reminder.shot"]
        waitHittable(shot)
        shot.tap()
        scheduled = waitProbe(app, contains: "log.shot.2026-11-29")
        let ids = Set(scheduled.split(separator: " ").map(String.init))
        XCTAssertTrue(ids.contains("log.weigh.2026-11-25"))
        XCTAssertTrue(ids.contains("log.checkin.2026-11-25"))
        XCTAssertTrue(ids.contains("log.shot.2026-11-29"))
        XCTAssertTrue(turnedOn(shot))
        XCTAssertFalse(app.staticTexts["reminders.denied"].exists)
    }

    func testLocalRemindersStayOffWhenPermissionIsDenied() {
        let app = launch("log", [
            "-now", "2026-11-24T23:20:00-06:00",
            "-scrollTo", "reminders",
            "-scriptedReminders",
            "-reminderDenied",
        ])
        let shot = app.switches["reminder.shot"]
        waitHittable(shot)
        shot.tap()
        let denied = app.staticTexts["reminders.denied"]
        XCTAssertTrue(denied.waitForExistence(timeout: 8))
        XCTAssertTrue(denied.label.contains("Notifications are off for Log"))
        XCTAssertFalse(turnedOn(shot))

        let probe = app.staticTexts["reminders.scheduled"]
        XCTAssertTrue(probe.waitForExistence(timeout: 8))
        let text = (probe.value as? String) ?? probe.label
        XCTAssertFalse(text.contains("log."))
    }

    func testWeighInPhotoPromptOnToday() {
        let app = launch("today", ["-now", "2026-11-24T23:20:00-06:00", "-scrollTo", "photo"])
        let prompt = app.staticTexts["today.photo.prompt"]
        waitHittable(prompt)
        XCTAssertTrue(prompt.label.contains("progress photo"), prompt.label)
        waitHittable(app.buttons["today.photo.add"]).tap()
        let offer = app.staticTexts["weigh.photo"]
        XCTAssertTrue(offer.waitForExistence(timeout: 8))
        waitHittable(app.buttons["weigh.camera"]).tap()
        let note = app.staticTexts["weigh.photo.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        XCTAssertTrue(note.label.contains("available on this device"), note.label)
        waitHittable(app.buttons["weigh.photo.dismiss"]).tap()
        let offerGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 0"), object: offer)
        XCTAssertEqual(XCTWaiter().wait(for: [offerGone], timeout: 8), .completed)
        waitHittable(app.buttons["today.photo.dismiss"]).tap()
        let promptGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 0"), object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [promptGone], timeout: 8), .completed)
    }

    func testWeighInOffersAPhotoPrompt() {
        let app = launch("log", ["-scrollTo", "weigh", "-now", "2026-11-24T23:20:00-06:00"])
        let field = app.textFields["weigh.weight"]
        waitHittable(field)
        field.tap()
        field.typeText("200")
        if app.keyboards.count > 0 {
            let done = app.buttons["Done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
        }
        let save = app.buttons["weigh.save"]
        waitHittable(save)
        save.tap()

        let photo = app.staticTexts["weigh.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertEqual(photo.label, "Add a progress photo")
        let message = app.staticTexts["form.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        XCTAssertEqual(message.label, "Logged 200 lb.")
        XCTAssertTrue(app.buttons["weigh.library"].exists)

        waitHittable(app.buttons["weigh.camera"]).tap()
        let note = app.staticTexts["weigh.photo.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        XCTAssertTrue(note.label.contains("available on this device"), note.label)

        waitHittable(app.buttons["weigh.photo.dismiss"]).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 0"), object: photo)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 8), .completed)
    }

    private func launch(_ tab: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", tab, "-uiTest"] + extra
        app.launch()
        return app
    }

    @discardableResult
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 20) -> XCUIElement {
        let ready = NSPredicate(format: "exists == 1 AND isHittable == 1")
        let exp = XCTNSPredicateExpectation(predicate: ready, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed, "\(element) did not become hittable")
        return element
    }

    @discardableResult
    private func waitProbe(_ app: XCUIApplication, contains needle: String, timeout: TimeInterval = 8) -> String {
        let probe = app.staticTexts["reminders.scheduled"]
        let ready = NSPredicate(format: "exists == 1 AND (value CONTAINS %@ OR label CONTAINS %@)", needle, needle)
        let exp = XCTNSPredicateExpectation(predicate: ready, object: probe)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed, "scheduled reminders never included \(needle)")
        return (probe.value as? String) ?? probe.label
    }

    private func turnedOn(_ element: XCUIElement) -> Bool {
        switch element.value {
        case let text as String: return text == "1"
        case let number as NSNumber: return number.intValue == 1
        default: return false
        }
    }
}
