import XCTest
@testable import LogUI

private final class PostCount {
    var reminders = 0
    var trends = 0
}

private final class TabLog {
    var values: [Int] = []
}

final class NavigationTests: XCTestCase {
    @MainActor
    func testOpenPostsOnceAndKeepsTheRoute() async {
        let posts = PostCount()
        let reminders = NotificationCenter.default.addObserver(forName: ReminderRouter.opened, object: nil, queue: .main) { _ in
            posts.reminders += 1
        }
        let trends = NotificationCenter.default.addObserver(forName: TrendsRouter.opened, object: nil, queue: .main) { _ in
            posts.trends += 1
        }
        defer {
            NotificationCenter.default.removeObserver(reminders)
            NotificationCenter.default.removeObserver(trends)
            ReminderRouter.pending = nil
            TrendsRouter.pending = nil
            TodayTabs.onSelect = nil
        }

        ReminderRouter.open("weigh")
        TrendsRouter.open("body", card: "readiness")
        // A second post would land inside this window (the old delays were 0.4s and 0.5s).
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(posts.reminders, 1)
        XCTAssertEqual(posts.trends, 1)
        XCTAssertEqual(ReminderRouter.pending, "weigh")
        XCTAssertEqual(TrendsRouter.pending?.section, "body")
        XCTAssertEqual(TrendsRouter.pending?.card, "readiness")
    }

    @MainActor
    func testWidgetAndReminderRoutes() {
        let tabs = TabLog()
        TodayTabs.onSelect = { tabs.values.append($0) }
        defer {
            TodayTabs.onSelect = nil
            ReminderRouter.pending = nil
            TrendsRouter.pending = nil
        }
        func link(_ s: String) -> URL { URL(string: s)! }

        DeepLink.open(link("pranaybop-log://today"))
        DeepLink.open(link("pranaybop-log://meds"))
        DeepLink.open(link("pranaybop-log://log"))
        XCTAssertNil(TrendsRouter.pending)

        DeepLink.open(link("pranaybop-log://trends/weight"))
        XCTAssertEqual(TrendsRouter.pending?.section, "weight")
        XCTAssertNil(TrendsRouter.pending?.card)

        DeepLink.open(link("pranaybop-log://trends/body"))
        XCTAssertEqual(TrendsRouter.pending?.section, "body")
        XCTAssertEqual(TrendsRouter.pending?.card, "readiness")

        ReminderRouter.open("checkin")
        XCTAssertEqual(ReminderRouter.pending, "checkin")
        ReminderRouter.open("meds")
        XCTAssertEqual(ReminderRouter.pending, "meds")
        ReminderRouter.open("weigh")
        XCTAssertEqual(ReminderRouter.pending, "weigh")
        ReminderRouter.open("progress")
        XCTAssertEqual(TrendsRouter.pending?.section, "weight")
        XCTAssertEqual(TrendsRouter.pending?.card, "progress")

        let count = tabs.values.count
        DeepLink.open(link("https://example.com"))
        XCTAssertFalse(DeepLink.handles(link("https://example.com")))
        XCTAssertEqual(tabs.values.count, count)
        XCTAssertEqual(tabs.values, [0, 1, 3, 2, 2, 0, 1, 3, 2])
    }
}
