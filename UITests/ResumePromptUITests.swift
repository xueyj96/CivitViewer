import XCTest
import UIKit

final class ResumePromptUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchQA(_ scenario: String) {
        app = XCUIApplication()
        let runID = UUID().uuidString
        print("RESUME_QA_RUN_ID=\(runID)")
        app.launchArguments = [
            "--qa-resume-prompt",
            "--qa-resume-prompt-ui",
            "--qa-resume-prompt-reset",
            "--qa-scenario=\(scenario)",
            "--qa-run-id=\(runID)"
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].waitForExistence(timeout: 20), "QA observer must become available")
    }

    func testNilContinuationRestoreToastExpiresAndPromptStaysConsumed() {
        launchQA("restore-legacy-nil")

        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "The seeded legacy checkpoint should offer resume")
        resume.tap()

        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已恢复保存的片段")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "Tap should restore the nil-continuation checkpoint and show success")
        attachScreenshot(named: "nil-continuation-success-notice")
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "Success notice should expire without another interaction")

        let viewport = activeMediaDeck()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        viewport.swipeUp()
        mainTabButton("作者榜").tap()
        mainTabButton("时间线").tap()
        XCTAssertFalse(resume.exists, "Consumed prompt must not return after swipe and tab navigation")
        XCTAssertFalse(notice.exists, "Expired success notice must stay dismissed after redraw")
    }

    func testNilContinuationRestoreToastCanBeClosedByRealTap() {
        launchQA("restore-legacy-nil")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        app.buttons["timeline.notice.close"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3), "The close control must dismiss the informational notice")
        activeMediaDeck().swipeUp()
        mainTabButton("作者榜").tap()
        mainTabButton("时间线").tap()
        XCTAssertFalse(resume.exists, "Closing the toast must not revive the consumed prompt")
        XCTAssertFalse(notice.exists)
    }

    func testVideoSeekRemainsTouchableWhileRestoreNoticeIsVisibleAndPlayerIsMuted() {
        launchQA("restore-video-legacy-nil")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        let player = app.descendants(matching: .any)["qa.player.muted"].firstMatch
        XCTAssertTrue(player.waitForValueToContain("muted", timeout: 20), "The native AVPlayerLayer must be present and muted before timing the notice")
        XCTAssertEqual(player.value as? String, "muted", "QA must remain silent at the player instance")
        let seekElements = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度"))
        XCTAssertEqual(seekElements.count, 1, "There must be exactly one exposed playback seek control")
        let seek = seekElements.firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10), "VideoSeekControl should be accessible by its production label")
        XCTAssertEqual(seek.label, "播放进度")
        let page = app.descendants(matching: .any)["media-page-28029101"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let seekFrame = seek.frame
        let pageFrame = page.frame
        let deckFrame = activeMediaDeck().frame
        let frameReceipt = "label=\(seek.label); seekFrame=\(seekFrame); pageFrame=\(pageFrame); deckFrame=\(deckFrame); seekHierarchy=\(seek.debugDescription)"
        print("RESUME_SEEK_FRAME \(frameReceipt)")
        XCTContext.runActivity(named: "Exact playback seek UI element and frame") { activity in
            activity.add(XCTAttachment(string: frameReceipt))
        }
        XCTAssertEqual(seekFrame.height, 44, accuracy: 1, "The exact playback seek accessibility element must expose the production 44pt UIControl frame. \(frameReceipt)")
        XCTAssertGreaterThan(seekFrame.midY, pageFrame.midY, "The seek control must sit in the lower portion of the media page. \(frameReceipt)")
        XCTAssertGreaterThanOrEqual(pageFrame.maxY - seekFrame.maxY, -1, "The seek control must stay within the media page bottom. \(frameReceipt)")
        XCTAssertLessThanOrEqual(pageFrame.maxY - seekFrame.maxY, 160, "The seek control must be near the bottom footer of the media page. \(frameReceipt)")
        XCTAssertTrue(seek.isHittable, "The active 44pt seek control must be ready before the notice timer starts")

        resume.tap()
        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已恢复保存的片段")).firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(notice.exists, "The notice must still be visible before touching seek")
        XCTAssertTrue(seek.isHittable, "The real seek control must remain hittable while the notice is on screen")
        let before = seek.valueDescription
        attachScreenshot(named: "video-seek-with-restore-notice")
        let beforeSeconds = seekSeconds(before)
        XCTAssertNotNil(beforeSeconds, "Could not parse the player's current progress: \(before)")
        let didSeek = expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: seek)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)).tap()
        wait(for: [didSeek], timeout: 3)
        let after = seek.valueDescription
        guard let afterSeconds = seekSeconds(after), let beforeSeconds else {
            XCTFail("Could not parse the seek readback before=\(before) after=\(after)")
            return
        }
        XCTAssertLessThanOrEqual(abs(afterSeconds - 21), 2, "A real tap at 70% of the 30-second fixture should seek near 21 seconds. before=\(before), after=\(after)")
        XCTAssertGreaterThanOrEqual(abs(afterSeconds - beforeSeconds), 5, "The actual playback position must jump well beyond natural playback drift. before=\(before), after=\(after)")
        attachScreenshot(named: "video-seek-landed-near-21-seconds")
    }

    func testRestoreFailureRemainsVisibleUntilTappedClosed() {
        launchQA("restore-failure")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()

        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(notice.exists, "Error notice must not use the informational auto-expiry")
        let before = app.descendants(matching: .any)["qa-state"].valueDescription
        app.buttons["timeline.notice.close"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3))
        XCTAssertTrue(before.contains("focus=28029101"), "Failed restore should preserve the visible focus")
        XCTAssertFalse(resume.exists, "The failed checkpoint is consumed when the user taps resume")
    }

    func testExpiredSuccessTimerCannotClearLaterRestartError() {
        launchQA("restore-legacy-nil-then-restart-failure")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()

        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已恢复保存的片段")).firstMatch.waitForExistence(timeout: 3))
        attachScreenshot(named: "success-before-restart-error")
        let pageState = app.descendants(matching: .any)["qa-state"]
        let beforeRestart = pageState.valueDescription
        let firstPageCount = metric("firstPageRequests", in: beforeRestart)
        let requestCount = metric("pageRequests", in: beforeRestart)
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(app.buttons["timeline.notice.retry"].waitForExistence(timeout: 12))
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        XCTAssertTrue(pageState.waitForValueToContain("lastCursor=nil", timeout: 10))
        XCTAssertEqual(metric("pageRequests", in: pageState.valueDescription) - requestCount, 1, "The actual timeline tab double tap must emit exactly one request")
        XCTAssertEqual(metric("firstPageRequests", in: pageState.valueDescription) - firstPageCount, 1, "The actual timeline tab double tap must issue exactly one first page")

        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(notice.exists, "The older success timer must not clear the newer persistent error")
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        let beforeClosingError = pageState.valueDescription
        let firstPagesBeforeClose = metric("firstPageRequests", in: beforeClosingError)
        app.buttons["timeline.notice.close"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 5)
        mainTabButton("作者榜").tap()
        mainTabButton("时间线").tap()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(metric("firstPageRequests", in: pageState.valueDescription), firstPagesBeforeClose,
                       "Closing a retry-from-start error must not trigger an implicit retry during ten seconds including a real tab cycle")
    }

    func testFailedSavedCursorCanBeRetriedFromFirstPageByRealTap() {
        launchQA("restore-stale-cursor")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        let viewport = activeMediaDeck()
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.swipeUp()
        viewport.swipeUp()

        let retry = app.buttons["feed.continuation.restart"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15), "A failed saved cursor should expose the production recovery action")
        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(notice.exists, "Retryable error notice must remain until action")
        let beforeRetry = app.descendants(matching: .any)["qa-state"].valueDescription
        let requestsBeforeRetry = metric("pageRequests", in: beforeRetry)
        let firstPagesBeforeRetry = metric("firstPageRequests", in: beforeRetry)
        retry.tap()
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("lastCursor=nil", timeout: 15))
        XCTAssertEqual(metric("pageRequests", in: state.valueDescription) - requestsBeforeRetry, 1, "The real retry tap must produce one new request")
        XCTAssertEqual(metric("firstPageRequests", in: state.valueDescription) - firstPagesBeforeRetry, 1, "The retry tap must issue exactly one first-page request")
        XCTAssertTrue(state.valueDescription.contains("lastSource=recommendation"))
    }

    func testNonTimelineDoubleTapDoesNotRefreshAndTimelineDoubleTapUsesFirstPage() {
        launchQA("restart-recommendation")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 15), "Recommendation lane must be seeded; state=\(state.valueDescription)")
        let initialState = state.valueDescription
        XCTAssertTrue(initialState.contains("recFocus=28029101"))
        XCTAssertTrue(initialState.contains("recCursor=qa-next"))
        XCTAssertTrue(initialState.contains("recQueueCount=5"))

        mainTabButton("作者榜").doubleTap()
        mainTabButton("时间线").tap()
        XCTAssertTrue(state.valueDescription.contains("recFirstPageRequests=0"), "Other tab double tap must not restart")
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029101"), "Single selection must preserve focus")
        XCTAssertTrue(state.valueDescription.contains("recCursor=qa-next"), "Single selection must preserve the old cursor")
        XCTAssertTrue(state.valueDescription.contains("recQueueCount=5"), "Single selection must preserve the loaded queue")

        mainTabButton("作者榜").tap()
        XCTAssertTrue(state.valueDescription.contains("recFirstPageRequests=0"), "Leaving Timeline must not request a page")
        let timelineTab = mainTabButton("时间线")
        timelineTab.doubleTap()
        XCTAssertTrue(state.waitForValueToContain("recFirstPageRequests=1", timeout: 10), "Real timeline double tap from Works should issue one first-page request")
        XCTAssertTrue(state.valueDescription.contains("recCursor=nil"), "Restart request must leave the recommendation lane at its initial-page cursor")
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029101"), "A successful restart should focus the first returned item")
        XCTAssertTrue(state.valueDescription.contains("recQueueCount=5"), "The refreshed queue should contain only the new first page")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(state.valueDescription.contains("recFirstPageRequests=1"), "One double tap must not issue duplicate first-page requests")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "接着看")).firstMatch.exists)
    }

    func testDoubleTapTimelineFromAnotherTabRestartsFollowingQueueWithExistingFilter() {
        launchQA("restart-following")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("followQueueCount=5", timeout: 15))

        app.buttons["timeline.source.following"].tap()
        XCTAssertTrue(state.waitForValueToContain("source=following", timeout: 10))
        XCTAssertTrue(state.valueDescription.contains("kind=video"))
        XCTAssertTrue(state.valueDescription.contains("sort=Most Comments"))
        XCTAssertTrue(state.valueDescription.contains("period=Month"))

        let beforeLeaving = state.valueDescription
        let firstPageBeforeLeaving = metric("firstPageRequests", in: beforeLeaving)
        let requestsBeforeLeaving = metric("pageRequests", in: beforeLeaving)
        mainTabButton("作者榜").tap()
        let afterSingleWorksTap = state.valueDescription
        XCTAssertEqual(metric("firstPageRequests", in: afterSingleWorksTap), firstPageBeforeLeaving, "Single navigation to Works must not issue a first-page request")
        XCTAssertEqual(metric("pageRequests", in: afterSingleWorksTap), requestsBeforeLeaving, "Single navigation to Works must preserve the request count")
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(state.waitForValueToContain("lastSource=following", timeout: 15))
        let readback = state.valueDescription
        XCTAssertTrue(readback.contains("lastSource=following"), "Refresh from Works must apply to the active followed lane")
        XCTAssertTrue(readback.contains("lastKind=video;lastSort=Most Comments;lastPeriod=Month"), "Refresh must retain filter and sort")
        XCTAssertTrue(readback.contains("lastCursor=nil"), "Refresh must discard the old continuation cursor")
        XCTAssertTrue(readback.contains("followFocus=28029101"), "The first returned item should become focused")
        XCTAssertTrue(readback.contains("followQueueCount=5"), "The refreshed queue should use the first page")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("firstPageRequests", in: state.valueDescription) - metric("firstPageRequests", in: afterSingleWorksTap), 1,
                       "One double tap from Works must issue exactly one new first-page request")
    }

    func testSelectedTimelineSingleTapReturnsToTopAndDoubleTapRestarts() {
        launchQA("restart-recommendation")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 15))
        let deck = activeMediaDeck()
        deck.swipeUp()
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029102", timeout: 10), state.valueDescription)
        deck.swipeUp()
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029103", timeout: 10), state.valueDescription)
        let before = state.valueDescription
        let firstPages = metric("recFirstPageRequests", in: before)
        let timeline = mainTabButton("时间线")
        timeline.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029101", timeout: 5), "Single reselect must return to the first loaded work; actual=\(state.valueDescription)")
        XCTAssertEqual(metric("recFirstPageRequests", in: state.valueDescription), firstPages)
        timeline.doubleTap()
        XCTAssertTrue(state.waitForValueToContain("recFirstPageRequests=\(firstPages + 1)", timeout: 10), state.valueDescription)
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029101", timeout: 10), state.valueDescription)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("recFirstPageRequests", in: state.valueDescription), firstPages + 1)
    }

    func testFollowingReselectReturnsToItsOwnTopAndDoubleTapRefreshesOnlyFollowing() {
        launchQA("restart-following")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 15))
        activeMediaDeck().swipeUp()
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029102", timeout: 10), state.valueDescription)
        app.buttons["timeline.source.following"].tap()
        XCTAssertTrue(state.waitForValueToContain("followQueueCount=5", timeout: 15))
        activeMediaDeck().swipeUp()
        XCTAssertTrue(state.waitForValueToContain("followFocus=28029102", timeout: 10), state.valueDescription)
        let before = state.valueDescription
        let followingPages = metric("followFirstPageRequests", in: before)
        let recommendationPages = metric("recFirstPageRequests", in: before)
        mainTabButton("时间线").tap()
        XCTAssertTrue(state.waitForValueToContain("followFocus=28029101", timeout: 5), state.valueDescription)
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029102"), "Return-to-top must not move the inactive recommendation lane")
        XCTAssertEqual(metric("followFirstPageRequests", in: state.valueDescription), followingPages)
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(state.waitForValueToContain("followFirstPageRequests=\(followingPages + 1)", timeout: 10), state.valueDescription)
        let readback = state.valueDescription
        XCTAssertTrue(readback.contains("lastSource=following"))
        XCTAssertTrue(readback.contains("lastKind=video;lastSort=Most Comments;lastPeriod=Month;lastCursor=nil"))
        XCTAssertTrue(readback.contains("recFocus=28029102"), "Following refresh must preserve the inactive recommendation focus")
        XCTAssertEqual(metric("recFirstPageRequests", in: readback), recommendationPages)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("followFirstPageRequests", in: state.valueDescription), followingPages + 1)
    }

    func testShortQueueSingleTapDoesNotRetryContinuation() {
        for count in 2...4 {
            launchQA("restart-short-\(count)")
            let state = app.descendants(matching: .any)["qa-state"]
            XCTAssertTrue(state.waitForValueToContain("recQueueCount=\(count)", timeout: 15))
            activeMediaDeck().swipeUp()
            XCTAssertTrue(state.waitForValueToContain("recFocus=28029102", timeout: 10), state.valueDescription)
            XCTAssertTrue(app.buttons["加载失败，点此重试"].waitForExistence(timeout: 10), "The fixture must have a failed ordinary continuation before reselecting")
            Thread.sleep(forTimeInterval: 1)
            let before = state.valueDescription
            XCTAssertTrue(before.contains("recCursor=qa-next"))
            let totalRequests = metric("pageRequests", in: before)
            let firstPages = metric("recFirstPageRequests", in: before)
            mainTabButton("时间线").tap()
            XCTAssertTrue(state.waitForValueToContain("recFocus=28029101", timeout: 5), state.valueDescription)
            Thread.sleep(forTimeInterval: 2)
            let after = state.valueDescription
            XCTAssertEqual(metric("pageRequests", in: after), totalRequests, "A single return-to-top must not retry a failed continuation for \(count) rows")
            XCTAssertEqual(metric("recFirstPageRequests", in: after), firstPages)
            XCTAssertTrue(after.contains("recQueueCount=\(count)"))
            XCTAssertTrue(after.contains("recCursor=qa-next"))
            attachScreenshot(named: "short-queue-\(count)-after-return-to-top")
            activeMediaDeck().swipeUp()
            XCTAssertTrue(state.waitForValueToContain("pageRequests=\(totalRequests + 1);", timeout: 10), "An actual swipe after return-to-top must re-enable ordinary loading")
        }
    }

    func testCollectionViewerPagesAfterRealFavoritesEntryAndRotation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let favorites = app.buttons["我的收藏"]
        if !favorites.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        favorites.tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        attachScreenshot(named: "favorites-grid-before-opening")
        for index in [0, 1, 2, 4, 5, 0] {
            let cell = app.buttons["media.grid.cell.\(28_037_100 + index)"]
            if !cell.waitForExistence(timeout: 10) { app.swipeDown() }
            XCTAssertTrue(cell.waitForExistence(timeout: 10))
            if !cell.isHittable { if index == 0 { app.swipeDown() } else { app.swipeUp() } }
            cell.tap()
            let geometry = app.staticTexts["collection.qa.geometry"]
            XCTAssertTrue(geometry.waitForExistence(timeout: 10))
            XCTAssertTrue(geometry.waitForValueToContain("focused=\(28_037_100 + index)", timeout: 10))
            attachScreenshot(named: "favorites-entry-\(index)")
            print("COLLECTION_GEOMETRY_ENTRY \(geometry.valueDescription)")
            assertCollectionPageAligned(geometry)
            if index == 2 {
                app.buttons["手动切换横竖屏"].tap()
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
                attachScreenshot(named: "favorites-video-landscape")
                print("COLLECTION_GEOMETRY_LANDSCAPE \(geometry.valueDescription)")
                app.buttons["手动切换横竖屏"].tap()
                attachScreenshot(named: "favorites-video-return-portrait")
                assertCollectionPageAligned(geometry)
                viewportDoubleTapAuthorAndReturn()
            }
            let viewport = app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.scrollViews.firstMatch
            XCTAssertTrue(viewport.exists)
            if index < 5 {
                viewport.swipeUp()
                XCTAssertTrue(geometry.waitForValueToContain("focused=\(28_037_101 + index)", timeout: 5), "An upward swipe must actually select the next work")
                attachScreenshot(named: "favorites-after-swipe-\(index)")
                print("COLLECTION_GEOMETRY_SWIPE \(geometry.valueDescription)")
                assertCollectionPageAligned(geometry)
            }
            app.buttons["关闭作品"].tap()
            XCTAssertTrue(cell.waitForExistence(timeout: 5))
        }
    }

    private func assertCollectionPageAligned(_ geometry: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            let pairs = geometry.valueDescription.split(separator: ";").compactMap { entry -> (String, Double)? in
                let parts = entry.split(separator: "="); guard parts.count == 2, let number = Double(parts[1]) else { return nil }
                return (String(parts[0]), number)
            }
            let values = Dictionary(uniqueKeysWithValues: pairs)
            guard let py = values["pageY"], let vy = values["viewportY"], let ph = values["pageH"], let vh = values["viewportH"] else { return false }
            return abs(py - vy) < 1 && abs(ph - vh) < 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: geometry)], timeout: 5), .completed,
                       "A settled page must fill and align with its viewport: \(geometry.valueDescription)", file: file, line: line)
    }

    private func viewportDoubleTapAuthorAndReturn(screenshotName: String = "favorites-video-double-tap-author", statusBarScheme: String? = nil) {
        let viewport = app.scrollViews.matching(identifier: "media.viewer.deck").firstMatch
        XCTAssertTrue(viewport.exists)
        viewport.doubleTap()
        XCTAssertTrue(app.navigationBars["作者作品"].waitForExistence(timeout: 5))
        if let statusBarScheme {
            let legible = NSPredicate { _, _ in self.statusBarGlyphPixels(scheme: statusBarScheme) > 100 }
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: legible, object: nil)], timeout: 5)
            if let image = UIImage(data: app.screenshot().pngRepresentation)?.cgImage {
                print("THEME_STATUS_FORMAT bits=\(image.bitsPerComponent)/\(image.bitsPerPixel) alpha=\(image.alphaInfo.rawValue) bitmap=\(image.bitmapInfo.rawValue) size=\(image.width)x\(image.height)")
            }
            print("THEME_STATUS_BAR_\(statusBarScheme) glyphPixels=\(statusBarGlyphPixels(scheme: statusBarScheme))")
            print("THEME_STATUS_AX \(app.statusBars.debugDescription.prefix(2400))")
            attachScreenshot(named: screenshotName + "-status-check")
            XCTAssertEqual(result, .completed,
                           "The status clock must have visible foreground pixels over the ordinary author page")
        }
        attachScreenshot(named: screenshotName)
        let back = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
    }

    func testTimelinePresentationSharesQueueAndPreservesGridReturn() {
        launchQA("restart-presentation")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("queueCount=3", timeout: 10))
        XCTAssertFalse(mainTabButton("作品榜").exists)
        let mode = app.buttons["timeline.presentation"]
        XCTAssertTrue(mode.waitForValueToContain("双列网格", timeout: 5))
        attachScreenshot(named: "timeline-grid-shared-queue")
        let initial = metric("pageRequests", in: state.valueDescription)
        XCTAssertEqual(initial, 0, "The controlled fixture seeds three works and a live continuation without issuing an initial request")
        mode.tap()
        XCTAssertTrue(mode.waitForValueToContain("信息流", timeout: 5))
        let unexpectedRead = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.metric("pageRequests", in: state.valueDescription) > initial }, object: state)
        unexpectedRead.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedRead], timeout: 2), .completed)
        mode.tap()
        XCTAssertTrue(mode.waitForValueToContain("双列网格", timeout: 5))
        let cell = app.buttons["media.grid.cell.28029102"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        let originalFrame = cell.frame
        cell.tap()
        XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
        // Opening the work is an explicit browsing action, so tail pagination
        // must remain usable while the lane is covered by this viewer.
        XCTAssertTrue(state.waitForValueToContain("pageRequests=\(initial + 1)", timeout: 10))
        attachScreenshot(named: "timeline-grid-selected-fullscreen")
        app.buttons["关闭作品"].tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertEqual(cell.frame.minY, originalFrame.minY, accuracy: 2)
        XCTAssertEqual(metric("pageRequests", in: state.valueDescription), initial + 1)
        attachScreenshot(named: "timeline-grid-return-original-position")
    }

    func testDurationRangeUsesActualTwoThumbDragsAndReset() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-duration-filter"]; app.launch()
        let state = app.staticTexts["duration.qa.state"]
        XCTAssertTrue(state.waitForValueToContain("none", timeout: 5))
        let lower = durationHandle(lower: true), upper = durationHandle(lower: false)
        durationExposeHandles()
        let rail = (left: lower.frame.midX, right: upper.frame.midX)
        durationDrag(lower: true, seconds: 17, rail: rail)
        XCTAssertTrue(lower.waitForValueToContain("00:17", timeout: 5))
        durationMenu(lower: true, action: "增加1秒"); XCTAssertTrue(lower.waitForValueToContain("00:18", timeout: 5))
        durationMenu(lower: true, action: "减少1秒"); XCTAssertTrue(lower.waitForValueToContain("00:17", timeout: 5))
        durationDrag(lower: false, seconds: 75, rail: rail)
        XCTAssertTrue(upper.waitForValueToContain("01:15", timeout: 5))
        durationMenu(lower: false, action: "增加1秒"); XCTAssertTrue(upper.waitForValueToContain("01:16", timeout: 5))
        durationMenu(lower: false, action: "不限"); XCTAssertTrue(upper.waitForValueToContain("不限", timeout: 5))
        durationDrag(lower: true, seconds: nil, rail: rail)
        XCTAssertTrue(lower.waitForValueToContain("超过02:00", timeout: 5))
        durationDrag(lower: false, seconds: 2, rail: rail)
        XCTAssertTrue(upper.valueDescription.contains("不限"), "A strict lower terminal cannot acquire a finite empty upper interval")
        attachScreenshot(named: "duration40-strict-terminal-and-clamped-upper")
        durationMenu(lower: true, action: "设为02:00")
        XCTAssertTrue(lower.waitForValueToContain("02:00", timeout: 5)); XCTAssertFalse(lower.valueDescription.contains("超过"))
        durationDrag(lower: false, seconds: 120, rail: rail)
        XCTAssertTrue(upper.waitForValueToContain("02:00", timeout: 5)); XCTAssertFalse(upper.valueDescription.contains("不限"))
        attachScreenshot(named: "duration40-inclusive-equal-120")
        let reset = app.buttons["重置筛选"]
        for _ in 0..<3 { if !reset.isHittable { app.swipeUp() } }
        XCTAssertTrue(reset.isHittable); reset.tap()
        XCTAssertTrue(state.waitForValueToContain("none", timeout: 5))
        XCTAssertEqual(app.switches["筛选视频时长"].value as? String, "0")
        attachScreenshot(named: "duration40-reset-disabled")
    }

    func testDurationLegacy120AndCollectionActualMetadata() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-duration-filter", "--qa-duration-legacy"]; app.launch()
        durationExposeHandles()
        let lower = durationHandle(lower: true)
        XCTAssertTrue(lower.valueDescription.contains("02:00")); XCTAssertFalse(lower.valueDescription.contains("超过"))
        XCTAssertTrue(app.staticTexts["duration.qa.state"].valueDescription.contains("02:00—不限"), "The real old-JSON fixture must remain an inclusive finite lower bound")
        durationMenu(lower: true, action: "减少1秒"); XCTAssertTrue(lower.waitForValueToContain("01:59", timeout: 5))
        durationMenu(lower: true, action: "增加1秒"); XCTAssertTrue(lower.waitForValueToContain("02:00", timeout: 5)); XCTAssertFalse(lower.valueDescription.contains("超过"))
        attachScreenshot(named: "duration40-legacy-inclusive-120")
        app.terminate()
        app.launchArguments = ["--qa-collection-paging"]; app.launch()
        mainTabButton("我").tap(); app.buttons["我的收藏"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        app.buttons["收藏筛选与刷新"].tap(); app.buttons["筛选条件"].tap()
        durationExposeHandles(); XCTAssertFalse(app.staticTexts["排序与范围"].exists)
        let rail = (left: durationHandle(lower: true).frame.midX, right: durationHandle(lower: false).frame.midX)
        durationDrag(lower: false, seconds: 120, rail: rail)
        XCTAssertTrue(durationHandle(lower: false).waitForValueToContain("02:00", timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037102"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["media.grid.cell.28037104"].exists, "119.9 is below the finite <=120 upper bound; 120.1 is above it")
        attachScreenshot(named: "duration40-collection-finite-upper-119point9")
        app.buttons["收藏筛选与刷新"].tap(); app.buttons["筛选条件"].tap()
        durationExposeHandles(); durationMenu(lower: false, action: "不限")
        durationDrag(lower: true, seconds: nil, rail: rail)
        XCTAssertTrue(durationHandle(lower: true).waitForValueToContain("超过02:00", timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037104"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["media.grid.cell.28037102"].exists, "The strict terminal must retain 120.1 and exclude 119.9")
        attachScreenshot(named: "duration40-collection-strict-lower-120point1")
    }

    private func durationHandle(lower: Bool) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: lower ? "duration.range.minimum" : "duration.range.maximum").firstMatch
    }
    private func durationExposeHandles() {
        for _ in 0..<6 {
            if durationHandle(lower: true).isHittable && durationHandle(lower: false).isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(durationHandle(lower: true).isHittable); XCTAssertTrue(durationHandle(lower: false).isHittable)
    }
    private func durationDrag(lower: Bool, seconds: Int?, rail: (left: CGFloat, right: CGFloat)) {
        let width = rail.right - rail.left
        let finiteWidth = width - min(52, width * 0.25)
        let x = seconds.map { rail.left + CGFloat($0 - 2) / 118 * finiteWidth } ?? rail.right
        let handle = durationHandle(lower: lower)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: handle.frame.midY)))
    }
    private func durationMenu(lower: Bool, action: String) {
        let menu = app.buttons[lower ? "duration.range.minimum.menu" : "duration.range.maximum.menu"]
        for _ in 0..<3 { if !menu.isHittable { app.swipeDown() } }
        XCTAssertTrue(menu.isHittable); menu.tap()
        let choice = app.buttons[action]; XCTAssertTrue(choice.waitForExistence(timeout: 3)); choice.tap()
    }

    func testBiographyTwoLinesExpandCollapseAcrossTextAndFontCases() {
        for variant in ["short", "empty", "chinese", "english", "url", "narrow", "dynamic"] {
            app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-biography-case=\(variant)"]; app.launch()
            let body = app.descendants(matching: .any).matching(identifier: "creator.biography.body").firstMatch
            let toggle = app.buttons["creator.biography.toggle"]
            if variant == "empty" {
                XCTAssertFalse(body.exists); XCTAssertFalse(toggle.exists)
            } else if variant == "short" {
                XCTAssertTrue(body.waitForExistence(timeout: 5)); XCTAssertFalse(toggle.exists)
            } else {
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                let collapsed = body.frame
                attachScreenshot(named: "biography-\(variant)-before-layout-check")
                print("BIOGRAPHY_FRAMES case=\(variant) body=\(collapsed) toggle=\(toggle.frame)")
                // Native selectable Text exposes external AX selection padding;
                // compare the visible button-label center, with pixel review too.
                XCTAssertGreaterThanOrEqual(toggle.frame.midY, collapsed.maxY - 1)
                XCTAssertLessThanOrEqual(body.frame.maxX, app.frame.maxX + 1, "Selectable text's AX selection padding must remain within the screen")
                XCTAssertLessThanOrEqual(body.frame.width, (variant == "narrow" || variant == "dynamic" ? 320 : app.frame.width) + 1)
                attachScreenshot(named: "biography-\(variant)-collapsed-two-lines")
                toggle.tap()
                XCTAssertTrue(toggle.waitForValueToContain("已展开", timeout: 5))
                XCTAssertGreaterThan(body.frame.height, collapsed.height)
                attachScreenshot(named: "biography-\(variant)-expanded")
                for _ in 0..<4 { if !toggle.isHittable { app.swipeUp() } }
                XCTAssertTrue(toggle.isHittable)
                toggle.tap()
                XCTAssertTrue(toggle.waitForValueToContain("已收起", timeout: 5))
                XCTAssertEqual(body.frame.height, collapsed.height, accuracy: 1)
            }
            attachScreenshot(named: "biography-\(variant)-final")
            app.terminate()
        }
    }

    func testAppearanceAcrossTabsSheetsAndImmersiveReturn() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui"]
        app.launch()
        for (title, raw) in [("浅色", "light"), ("深色", "dark")] {
            mainTabButton("我").tap()
            chooseAppearance(title)
            XCTAssertTrue(app.descendants(matching: .any)["qa.theme.state"].waitForValueToContain("theme=\(raw)", timeout: 5))
            attachScreenshot(named: "theme-\(raw)-settings")
            let favorites = app.buttons["我的收藏"]
            for _ in 0..<4 { if !favorites.isHittable { app.swipeDown() } }
            XCTAssertTrue(favorites.isHittable); favorites.tap()
            attachScreenshot(named: "theme-\(raw)-collections")
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch.tap()
            let first = app.buttons["media.grid.cell.28037100"]
            XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
            XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-immersive-image")
            app.buttons["作品详情"].tap()
            XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-details-over-media")
            app.buttons["完成"].tap()
            XCTAssertTrue(app.staticTexts["collection.qa.geometry"].waitForValueToContain("focused=28037100", timeout: 5))
            // Scope this action to the focused work and its production label;
            // a parent SwiftUI identifier can shadow this button's own identifier.
            let favorite = app.buttons.matching(NSPredicate(format: "label == %@", "收藏")).allElementsBoundByIndex.first(where: { $0.isHittable })
            XCTAssertNotNil(favorite); favorite?.tap()
            XCTAssertTrue(app.navigationBars["收藏图片"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-favorite-editor-over-media")
            app.buttons["取消"].tap()
            viewportDoubleTapAuthorAndReturn(screenshotName: "theme-\(raw)-author-over-media", statusBarScheme: raw)
            attachScreenshot(named: "theme-\(raw)-immersive-return")
            app.buttons["关闭作品"].tap()
            mainTabButton("作者榜").tap()
            XCTAssertTrue(app.segmentedControls.buttons["Seasonal"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-authors")
            mainTabButton("搜索").tap()
            let field = app.textFields["search-title-input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            if field.valueDescription != "Pattern" { field.tap(); field.typeText("Pattern\n") }
            else { app.buttons["search-submit"].tap() }
            let searchFilter = app.buttons["search-filter-button"]
            XCTAssertTrue(searchFilter.waitForExistence(timeout: 5)); searchFilter.tap()
            XCTAssertTrue(app.navigationBars["浏览筛选"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-search-filter")
            app.buttons["完成"].tap()
            app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.tap()
            XCTAssertEqual(field.valueDescription, "Pattern", "Switching appearance and tabs must preserve search criteria")
            attachScreenshot(named: "theme-\(raw)-search")
            mainTabButton("时间线").tap()
            let mode = app.buttons["timeline.presentation"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            if raw == "dark" {
                XCTAssertTrue(mode.valueDescription.contains("双列网格"), "Theme changes must preserve the timeline presentation")
                XCTAssertTrue(app.segmentedControls["timeline.media-kind"].buttons["图片"].isSelected, "Theme changes must preserve the current media filter")
            }
            if !mode.valueDescription.contains("信息流") { mode.tap() }
            XCTAssertTrue(mode.waitForValueToContain("信息流", timeout: 5))
            attachScreenshot(named: "theme-\(raw)-timeline-stream")
            app.segmentedControls["timeline.media-kind"].buttons["图片"].tap()
            mode.tap()
            XCTAssertTrue(mode.waitForValueToContain("双列网格", timeout: 5))
            XCTAssertTrue(app.buttons["media.grid.cell.28037100"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-timeline-grid")
        }
        mainTabButton("我").tap()
        chooseAppearance("跟随系统")
    }

    func testSystemAppearanceUsesCurrentDeviceTrait() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui"]; app.launch()
        chooseAppearance("跟随系统")
        let state = app.descendants(matching: .any)["qa.theme.state"]
        XCTAssertTrue(state.waitForValueToContain("preference=system", timeout: 5))
        print("THEME_SYSTEM_OBSERVATION \(state.valueDescription)")
        attachScreenshot(named: "theme-system-current-device-settings")
        mainTabButton("搜索").tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        attachScreenshot(named: "theme-system-current-device-search")
    }

    func testThemeCompactDynamicTypeKeepsControlsUsable() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-theme-compact"]; app.launch()
        for title in ["浅色", "深色"] {
            mainTabButton("我").tap(); chooseAppearance(title)
            attachScreenshot(named: "theme-compact-dynamic-\(title)-settings")
            mainTabButton("搜索").tap()
            XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-compact-dynamic-\(title)-search")
        }
        mainTabButton("我").tap(); chooseAppearance("跟随系统")
    }

    private func statusBarGlyphPixels(scheme: String) -> Int {
        guard let image = UIImage(data: app.screenshot().pngRepresentation)?.cgImage,
              image.bitsPerComponent == 8, image.colorSpace?.model == .rgb,
              let bytes = image.dataProvider?.data else { return 0 }
        let values = CFDataGetBytePtr(bytes)!
        let pixelBytes = image.bitsPerPixel / 8
        guard pixelBytes >= 3 else { return 0 }
        let firstAlpha: Set<CGImageAlphaInfo> = [.first, .premultipliedFirst, .noneSkipFirst]
        let colorOffset = firstAlpha.contains(image.alphaInfo) ? 1 : 0
        // The clock occupies this fixed, portrait status-bar region. Nav titles,
        // media and QA labels lie outside it, so they cannot satisfy this check.
        var count = 0
        for y in Int(Double(image.height) * 0.018)..<Int(Double(image.height) * 0.055) {
            for x in Int(Double(image.width) * 0.11)..<Int(Double(image.width) * 0.29) {
                let start = y * image.bytesPerRow + x * pixelBytes + colorOffset
                let mean = (Int(values[start]) + Int(values[start + 1]) + Int(values[start + 2])) / 3
                if scheme == "light" ? mean < 80 : mean > 190 { count += 1 }
            }
        }
        return count
    }

    private func chooseAppearance(_ title: String) {
        // A retained tab can still show a pushed collection page.
        let settingsBar = app.navigationBars["账号与设置"]
        for _ in 0..<3 {
            if settingsBar.waitForExistence(timeout: 1), settingsBar.isHittable { break }
            let backs = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex
            guard let back = backs.first(where: { $0.isHittable }) else { break }
            back.tap()
        }
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 5))
        let picker = app.buttons["settings-appearance-picker"]
        // A large swipe can leave this row partially underneath an opaque nav
        // bar. Existence/hittability alone does not guarantee its center is exposed.
        app.swipeDown()
        let window = app.windows.firstMatch
        let navBottom = app.navigationBars["账号与设置"].frame.maxY
        let tabTop = mainTabBar().frame.minY
        for _ in 0..<8 {
            if picker.exists, picker.isHittable, picker.frame.midY > navBottom + 22, picker.frame.midY < tabTop - 22 { break }
            let downward = picker.exists && picker.frame.midY < navBottom + 22
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.35 : 0.60))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.60 : 0.35)))
        }
        XCTAssertTrue(picker.isHittable)
        XCTAssertGreaterThan(picker.frame.midY, navBottom + 22)
        XCTAssertLessThan(picker.frame.midY, tabTop - 22)
        attachScreenshot(named: "theme-picker-exposed-\(title)")
        picker.tap()
        let option = app.buttons[title]
        let appeared = option.waitForExistence(timeout: 5)
        if !appeared { attachScreenshot(named: "theme-picker-option-missing-\(title)"); print(String(app.debugDescription.prefix(12000))) }
        XCTAssertTrue(appeared); option.tap()
        XCTAssertTrue(picker.waitForValueToContain(title, timeout: 5))
    }

    func testVisualControlsPortraitMatrix() {
        for (width, large) in [(0, false), (375, false), (320, true)] {
            visualLaunch(width: width, large: large, landscape: false)
            visualTypeControls(caseName: "portrait-\(width)-large\(large)")
            visualSocialStates(caseName: "portrait-\(width)-large\(large)")
            app.terminate()
        }
    }

    func testVisualControlsLandscapeMatrix() {
        for (width, large) in [(440, false), (0, true)] {
            visualLaunch(width: width, large: large, landscape: true)
            visualTypeControls(caseName: "landscape-\(width)-large\(large)")
            visualSocialStates(caseName: "landscape-\(width)-large\(large)")
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testTimelineHeaderStaysCenteredInBothSources() {
        for (name, width, large, landscape) in [("portrait", 0, false, false), ("narrow-A2", 320, true, false), ("landscape", 0, false, true)] {
            visualLaunch(width: width, large: large, landscape: landscape)
            let presentation = app.buttons["timeline.presentation"]
            for source in ["following", "recommendation"] {
                let following = app.buttons["timeline.source.following"]
                let recommendation = app.buttons["timeline.source.recommendation"]
                app.buttons["timeline.source.\(source)"].tap()
                heightCloseNotices()
                app.segmentedControls["timeline.media-kind"].buttons["图片"].tap()
                waitUntil("The selected source must really show the first image") { self.watchFocus() == 28_037_100 }
                if landscape { visualEnsureLandscape() }
                heightWaitOrientation(landscape: landscape)
                let initialToolX = presentation.frame.midX
                let center = following.frame.union(recommendation.frame).midX
                XCTAssertEqual(center, heightDeck().frame.midX, accuracy: 1, "Source tabs must be centered in \(name)/\(source)")
                for button in [following, recommendation, presentation] {
                    XCTAssertTrue(button.isHittable)
                    XCTAssertGreaterThanOrEqual(button.frame.width + 0.01, 44)
                    XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44)
                }
                XCTAssertLessThanOrEqual(following.frame.maxX, recommendation.frame.minX)
                attachScreenshot(named: "floating44-\(name)-\(source)-image")
                app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
                waitPlayingFixture()
                if landscape { visualEnsureLandscape(); waitPlayingFixture() }
                heightWaitOrientation(landscape: landscape)
                XCTAssertEqual(following.frame.union(recommendation.frame).midX, heightDeck().frame.midX, accuracy: 1)
                XCTAssertEqual(presentation.frame.midX, initialToolX, accuracy: 1, "The grid control must stay in the same right slot at the same actual orientation")
                attachScreenshot(named: "floating44-\(name)-\(source)-video")
            }
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testFloatingHeaderAndBarRevealTallMedia() {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-chrome-geometry", "-app.appearance", "light"]
        app.launch(); heightOpen("recommendation", expected: 28_037_100)
        heightCloseNotices(); heightAssert("recommendation", phase: "floating44-tall-image", expected: 28_037_100)
        let image = captureChromePixels(named: "floating44-transparent-tall-image")
        let deck = heightDeck().frame, source = app.buttons["timeline.source.following"].frame, tabs = mainTabBar().frame
        // Uniform blue fixture pixels must remain visible in both formerly opaque header bands and through the bar.
        for (name, y) in [("source", source.minY + 12), ("filter-band", source.minY + 96), ("bar", tabs.minY + 4)] {
            let sample = CGRect(x: deck.midX - 2, y: y, width: 4, height: 4)
            XCTAssertGreaterThan(floating44BlueFraction(image, in: sample) ?? -1, 0.8, "Underlying blue image must be visible through \(name)")
        }
        let baseSample = CGRect(x: deck.midX - 2, y: source.minY + 96, width: 4, height: 4)
        let barSample = CGRect(x: deck.midX - 2, y: tabs.minY + 4, width: 4, height: 4)
        guard let baseColor = floating45MeanRGB(image, in: baseSample), let barColor = floating45MeanRGB(image, in: barSample) else {
            XCTFail("Actual image and navigation background pixels must be measurable"); return
        }
        XCTAssertLessThanOrEqual(barColor[0], baseColor[0] + 20, "The navigation strip must not add the former pale opaque material tint")
        XCTAssertGreaterThan(barColor[2], baseColor[2] * 0.5, "At least half the underlying blue signal must remain visible through the navigation strip")
        print("BAR45_ACTUAL_RGB base=\(baseColor);bar=\(barColor)")
        app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        XCTAssertTrue(videoGeometryReadback() != nil)
        attachScreenshot(named: "floating44-transparent-tall-video")
        app.terminate()
    }

    private func floating44BlueFraction(_ screenshot: UIImage?, in frame: CGRect) -> Double? {
        guard let image = screenshot?.cgImage, app.frame.width > 0, app.frame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / app.frame.width, sy = CGFloat(image.height) / app.frame.height
        let crop = CGRect(x: (frame.minX - app.frame.minX) * sx, y: (frame.minY - app.frame.minY) * sy, width: frame.width * sx, height: frame.height * sy).integral
        guard let region = image.cropping(to: crop), region.width > 0, region.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        guard let context = CGContext(data: &bytes, width: region.width, height: region.height, bitsPerComponent: 8, bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        let blue = stride(from: 0, to: bytes.count, by: 4).filter { Int(bytes[$0 + 2]) > Int(bytes[$0]) + 20 && bytes[$0 + 2] > 120 }.count
        return Double(blue) / Double(region.width * region.height)
    }

    private func floating45MeanRGB(_ screenshot: UIImage?, in frame: CGRect) -> [Double]? {
        guard let image = screenshot?.cgImage, app.frame.width > 0, app.frame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / app.frame.width, sy = CGFloat(image.height) / app.frame.height
        let crop = CGRect(x: (frame.minX - app.frame.minX) * sx, y: (frame.minY - app.frame.minY) * sy, width: frame.width * sx, height: frame.height * sy).integral
        guard let region = image.cropping(to: crop), region.width > 0, region.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        guard let context = CGContext(data: &bytes, width: region.width, height: region.height, bitsPerComponent: 8, bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        return (0..<3).map { channel in Double(stride(from: channel, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }) / Double(region.width * region.height) }
    }

    func testSettingsEmptyCacheUsesNumericZero() {
        visualLaunch(width: 0, large: false, landscape: false)
        mainTabButton("我").tap()
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 5))
        let clear = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "清理媒体缓存")).firstMatch
        for _ in 0..<8 { if clear.exists && clear.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(clear.isHittable); clear.tap()
        let row = app.descendants(matching: .any).matching(identifier: "settings.media-cache-size").firstMatch
        waitUntil("A successfully cleared cache must display the exact numeric zero, excluding 10/100 KB") {
            (row.label + " " + row.valueDescription).range(of: "(?<![0-9.,])0 KB(?![A-Za-z0-9])", options: .regularExpression) != nil
        }
        print("CACHE44_EXACT_ZERO label=\(row.label);value=\(row.valueDescription)")
        attachScreenshot(named: "floating44-settings-numeric-zero")
        app.terminate()
    }

    private func launchPlayback43(_ mode: String, automatic: Bool? = nil) {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=\(mode)",
                               "-automaticVideoRepair", (automatic ?? mode.hasPrefix("repair-")) ? "YES" : "NO", "-muted", "YES"]
        app.launch()
        let node = app.descendants(matching: .any).matching(identifier: "qa.playback-diagnostics43").firstMatch
        let appeared = node.waitForExistence(timeout: 10)
        if !appeared { print("PLAYBACK43_MISSING_READBACK mode=\(mode)\n\(app.debugDescription)"); attachScreenshot(named: "playback43-missing-readback-\(mode)") }
        XCTAssertTrue(appeared)
        print("PLAYBACK43_READBACK_NODE \(node.debugDescription)")
    }
    private func playback43Entries() -> [[String: Any]] {
        let raw = app.descendants(matching: .any).matching(identifier: "qa.playback-diagnostics43").firstMatch.valueDescription
        return ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]) ?? []
    }
    private func attachPlayback43(_ mode: String) {
        let raw = app.descendants(matching: .any).matching(identifier: "qa.playback-diagnostics43").firstMatch.valueDescription
        print("PLAYBACK43_FIXTURE mode=\(mode);synthetic=true;json=\(raw)")
        let attachment = XCTAttachment(string: raw); attachment.name = "playback43-\(mode)-synthetic-only"; attachment.lifetime = .keepAlways; add(attachment)
        attachScreenshot(named: "playback43-\(mode)")
    }
    func testPlaybackDiagnostics43ValidVideoDoesNotRecordFailure() {
        launchPlayback43("valid"); waitPlayingFixture()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(playback43Entries().isEmpty)
        XCTAssertEqual(playerFields()["created"], "1")
        attachPlayback43("valid")
    }
    func testPoster49CapturesCurrentDecodedFrameWithoutRepair() {
        launchPlayback43("poster-stream49")
        waitUntil("A failed declared JPEG should be replaced by the existing native player's current frame", timeout: 20) {
            self.playback43Entries().contains { $0["code"] as? String == "posterCaptured" }
        }
        let events = playback43Entries()
        let failure = events.first { $0["code"] as? String == "posterFailed" }?["playback"] as? [String: Any]
        XCTAssertEqual(failure?["posterStage"] as? String, "declaredImage")
        XCTAssertEqual(failure?["posterFailure"] as? String, "decode")
        XCTAssertFalse(events.contains { $0["code"] as? String == "repairStarted" }, "Capturing a displayed frame must not invoke conversion")
        XCTAssertEqual(playerFields()["created"], "1", "The existing native player supplies the frame")
        XCTAssertEqual(playerFields()["muted"], "true")
        let poster = app.descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 5))
        attachPlayback43("poster-stream49-current-frame")
        app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 5))
        let preview = app.descendants(matching: .any)["details.preview"]
        XCTAssertTrue(preview.exists)
        let detailPoster = preview.descendants(matching: .any)["poster.qa.146087479"]
        print("POSTER49_DETAIL \(detailPoster.debugDescription)")
        attachScreenshot(named: "poster49-details-visible-before-readback")
        XCTAssertTrue(detailPoster.waitForValueToContain("state=ready", timeout: 5))
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachScreenshot(named: "poster49-details-reuses-captured-frame")
    }

    private func launchPosterDetails50(missing: Bool = false) {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=poster-stream49",
                               "--qa-poster-details50", "-muted", "YES"] + (missing ? ["--qa-poster-missing50"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 10))
    }
    func testPoster50LocalVideoRepairsBrokenDeclaredCover() {
        launchPosterDetails50()
        let preview = app.descendants(matching: .any)["details.preview"]
        let poster = preview.descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 12))
        waitUntil("The local recovery and route must persist their finite diagnostic stages") {
            let events = self.playback43Entries()
            return events.contains { $0["code"] as? String == "posterOpened" && ($0["playback"] as? [String: Any])?["posterStage"] as? String == "detailsVideo" } &&
                events.contains { $0["code"] as? String == "posterLoaded" && ($0["playback"] as? [String: Any])?["posterStage"] as? String == "cacheWrite" }
        }
        let events = playback43Entries()
        XCTAssertFalse(events.contains { ["repairStarted", "posterCaptured", "posterCaptureStarted"].contains($0["code"] as? String ?? "") })
        XCTAssertFalse(app.descendants(matching: .any)["media.qa.player"].exists, "The detail preview must not create a player")
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachPlayback43("poster50-local-recovery")
    }
    func testPoster50UnavailableRouteIsRecordedWithoutRequest() {
        launchPosterDetails50(missing: true)
        waitUntil("A rejected source is recorded without inventing a URL or request") {
            self.playback43Entries().contains {
                let context = $0["playback"] as? [String: Any]
                return $0["code"] as? String == "posterOpened" && context?["posterStage"] as? String == "detailsUnavailable" && context?["source"] as? String == "unavailable"
            }
        }
        XCTAssertFalse(playback43Entries().contains { $0["code"] as? String == "posterStarted" })
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachPlayback43("poster50-unavailable-route")
    }

    func testPoster51FailedDetailRefreshesWhenAnotherProducerCachesFrame() {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=poster-stream49",
                               "--qa-poster-details50", "--qa-poster-late51", "-muted", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["details.preview"]
        let poster = preview.descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=failed", timeout: 12))
        XCTAssertTrue(app.buttons["details.poster.retry"].exists)
        let producer = app.buttons["poster.qa.generate51"]
        producer.tap()
        XCTAssertTrue(producer.waitForValueToContain("written", timeout: 3), "The real cache writer must commit a valid frame first")
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 5), "The existing failed detail must refresh without tapping retry or reopening")
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.qa.player"].exists, "Cache invalidation does not create a second player")
        attachPlayback43("poster51-late-cache-write")
    }

    func testToolbar49VideoCancelAndNativeBack() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49"])
        app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
        let favorite = app.buttons.matching(NSPredicate(format: "label == %@", "收藏")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(favorite); favorite?.tap()
        XCTAssertTrue(app.navigationBars["收藏视频"].waitForExistence(timeout: 5))
        let cancel = app.navigationBars["收藏视频"].buttons["取消"]
        attachScreenshot(named: "toolbar49-cancel-before-hit-check")
        waitUntil("The visible favorite-editor cancellation action becomes hittable") { cancel.isHittable }
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44)
        XCTAssertLessThanOrEqual(cancel.frame.height, 50, "Two Chinese glyphs must stay horizontal in the compact toolbar")
        attachScreenshot(named: "toolbar49-video-favorite-horizontal-cancel")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["收藏视频"].waitForNonExistence(timeout: 5))
        mainTabButton("作者榜").tap()
        XCTAssertFalse(app.buttons["navigation.back"].exists, "Root pages must not acquire a return action")
        let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pattern Creator 1")).firstMatch
        XCTAssertTrue(creator.waitForExistence(timeout: 5)); creator.tap()
        XCTAssertTrue(app.navigationBars["作者作品"].waitForExistence(timeout: 5))
        let state = app.descendants(matching: .any)["navigation.qa49"]
        XCTAssertTrue(state.waitForValueToContain("nativeBackHidden=true", timeout: 5))
        XCTAssertTrue(state.valueDescription.contains("edgeSwipe=true"))
        let back = app.navigationBars["作者作品"].buttons["navigation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        waitUntil("The single visible return action is hittable") { back.isHittable }
        XCTAssertEqual(app.navigationBars["作者作品"].buttons.matching(identifier: "navigation.back").count, 1)
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertLessThanOrEqual(back.frame.height, 50)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.35)))
        waitUntil("A predominantly vertical edge scroll retains the current page and usable return control") {
            back.isHittable && state.valueDescription.contains("depth=2") && state.valueDescription.contains("transition=false")
        }
        print("BACK49_AFTER_VERTICAL_EDGE \(state.valueDescription)")
        attachScreenshot(named: "toolbar49-flat-back-no-shared-glass")
        print("BACK49_BEFORE_SWIPE \(state.valueDescription)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        let returned = app.navigationBars["作者榜"].waitForExistence(timeout: 5)
        print("BACK49_AFTER_SWIPE \(state.valueDescription)")
        XCTAssertTrue(returned, "System interactive back swipe remains usable")
        XCTAssertFalse(app.buttons["navigation.back"].exists)
        creator.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(app.navigationBars["作者榜"].waitForExistence(timeout: 5), "The flat return control dismisses through SwiftUI")
    }
    func testFlatBack49NestedCollectionsAndNoAccess() {
        func openCollections() {
            mainTabButton("我").tap()
            let link = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的收藏")).firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
            XCTAssertTrue(app.navigationBars["我的收藏"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.navigationBars["我的收藏"].buttons.matching(identifier: "navigation.back").count, 1)
        }
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49"])
        openCollections()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        let bar = app.navigationBars["分页测试收藏"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(bar.buttons.matching(identifier: "navigation.back").count, 1)
        waitUntil("Nested collection return is hittable") { bar.buttons["navigation.back"].isHittable }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 1)
        print("BACK49_AFTER_SHORT_SWIPE \(app.descendants(matching: .any)["navigation.qa49"].valueDescription)")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "A short interactive pop cancels and retains the depth-three page")
        waitUntil("Cancelled transition keeps the return action usable") { bar.buttons["navigation.back"].isHittable }
        attachScreenshot(named: "toolbar49-depth3-cancelled-pop")
        bar.buttons["navigation.back"].tap()
        XCTAssertTrue(app.navigationBars["我的收藏"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation.back"].exists)
        app.terminate()
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49", "--qa-no-collection-access49"])
        openCollections()
        XCTAssertTrue(app.staticTexts["启用账号收藏"].exists)
        attachScreenshot(named: "toolbar49-no-collection-access-one-back")
        app.navigationBars["我的收藏"].buttons["navigation.back"].tap()
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 5))
    }
    func testRepair47VP9AutomaticallyEscalatesToH264AndDisplaysFrame() {
        assertAutomaticRepair47("repair-vp9", codec: 3)
    }
    func testRepair47VP8AutomaticallyTranscodesAndDisplaysFrame() {
        assertAutomaticRepair47("repair-vp8", codec: 4)
    }
    func testRepair47BrokenBrowserCacheStillRetriesOriginal() {
        launchPlayback43("bad-cache", automatic: true)
        waitPlayingFixture()
        let failures = playback43Entries().filter { $0["code"] as? String == "playbackFailed" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual((failures.first?["playback"] as? [String: Any])?["source"] as? String, "cache")
        XCTAssertEqual(playerFields()["created"], "2")
        XCTAssertEqual(playerFields()["muted"], "true")
        attachPlayback43("broken-cache-auto")
    }
    func testPreparation48KeepsOneLayerAcrossLoadingRepairAndPlayer() {
        app = XCUIApplication(); app.launchArguments = ["--qa-preparation48"]; app.launch()
        let panel = app.descendants(matching: .any).matching(identifier: "media.preparation").firstMatch
        let qa = app.descendants(matching: .any).matching(identifier: "media.qa.preparation48").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(qa.waitForExistence(timeout: 5))
        func state() -> String { qa.value as? String ?? qa.label }
        func identity() -> String {
            panel.valueDescription.components(separatedBy: ";").first ?? "missing"
        }
        let original = identity(), frame = panel.frame
        XCTAssertTrue(original.hasPrefix("id=")); XCTAssertTrue(panel.valueDescription.contains("progress=unknown"))
        XCTAssertTrue(state().contains("stage=native;visible=1;presented=1"))
        for button in ["修复 65%", "新播放器", "原生加载"] {
            app.buttons[button].tap()
            XCTAssertEqual(identity(), original)
            XCTAssertTrue(state().contains("visible=1;presented=1"))
            XCTAssertEqual(panel.frame.width, frame.width, accuracy: 1)
            XCTAssertEqual(panel.frame.height, frame.height, accuracy: 1)
            XCTAssertEqual(panel.frame.midX, frame.midX, accuracy: 1)
            XCTAssertEqual(panel.frame.midY, frame.midY, accuracy: 1)
        }
        app.buttons["修复 65%"].tap()
        XCTAssertTrue(panel.valueDescription.contains("progress=0.65"))
        XCTAssertTrue(state().contains("stage=repair;visible=1;presented=1"))
        XCTAssertFalse(state().contains("panel=0,0,0,0"), "The visible panel must publish its gesture exclusion frame")
        XCTAssertTrue(state().contains(",232,132"), "The published gesture frame must match the fixed panel size")
        attachScreenshot(named: "preparation48-one-stable-layer")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).press(forDuration: 0.65)
        waitUntil("A center hold outside the visible panel reaches the real gesture layer") {
            state().contains("chromeHoldCount=1")
        }
        XCTAssertTrue(state().contains("tapCount=0"), "The center hold must not also trigger tap")
        attachScreenshot(named: "preparation48-outside-center-hold")

        let cancelButton = app.buttons["取消"]
        let preparationTitle = app.staticTexts["正在准备视频"]
        preparationTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.65)
        let panelLongPressState = state()
        let panelLongPressFrames = "panel=\(panel.frame);cancel=\(cancelButton.frame);title=\(preparationTitle.frame)"
        print("PREPARATION48_PANEL_LONGPRESS state=\(panelLongPressState);\(panelLongPressFrames)")
        attachScreenshot(named: "preparation48-panel-long-press-excluded")
        XCTAssertTrue(panelLongPressState.contains("cancelCount=0;tapCount=0;chromeHoldCount=1"),
                      "A long press on the preparation panel must not reach tap or chrome hold; state=\(panelLongPressState); \(panelLongPressFrames)")

        app.buttons["取消"].tap()
        waitUntil("Preparation cancel updates QA state and disables panel") {
            state().contains("stage=hidden;visible=0;presented=0;cancelCount=1") &&
                state().contains("tapCount=0;chromeHoldCount=1") && state().contains("panel=0,0,0,0")
        }
        let cancel = app.buttons["取消"]
        XCTAssertTrue(!cancel.exists || !cancel.isHittable, "Cancelled preparation must not retain an active cancel target")
        attachScreenshot(named: "preparation48-cancelled-inert-panel")

        app.buttons["原生加载"].tap()
        waitUntil("The same panel can show again after cancellation") {
            state().contains("stage=native;visible=1;presented=1")
        }
        XCTAssertEqual(identity(), original)
        XCTAssertEqual(panel.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, frame.height, accuracy: 1)
    }
    private func assertAutomaticRepair47(_ mode: String, codec: Int) {
        launchPlayback43(mode)
        waitUntil("A repaired native player must display a frame and advance", timeout: 35) {
            self.playback43Entries().contains { $0["code"] as? String == "repairedVideoPlaying" }
        }
        let entries = playback43Entries()
        let begun = entries.first { $0["code"] as? String == "repairStarted" }?["playback"] as? [String: Any]
        let completed = entries.first { $0["code"] as? String == "repairCompleted" }?["playback"] as? [String: Any]
        XCTAssertEqual(begun?["videoCodec"] as? Int, codec)
        XCTAssertEqual(begun?["containerHint"] as? String, "ebml")
        XCTAssertEqual(completed?["repairMode"] as? String, "transcode")
        XCTAssertEqual(completed?["videoCodec"] as? Int, 1)
        XCTAssertEqual(completed?["containerHint"] as? String, "isoBmff")
        XCTAssertEqual(completed?["source"] as? String, "cache")
        XCTAssertEqual(playerFields()["muted"], "true")
        XCTAssertFalse(app.buttons["media.compatibility.open"].exists)
        attachPlayback43(mode)
    }
    func testPlaybackDiagnostics43TruncatedOfflineRetainsNativeErrorAndRetry() {
        launchPlayback43("invalid-offline")
        waitUntil("Both native offline failure attempts should persist", timeout: 15) {
            self.playback43Entries().compactMap { $0["playback"] as? [String: Any] }.count == 2
        }
        let contexts = playback43Entries().compactMap { $0["playback"] as? [String: Any] }
        XCTAssertEqual(Set(contexts.compactMap { $0["attempt"] as? Int }), [0, 1])
        for context in contexts {
            XCTAssertEqual(context["workID"] as? Int, 146_853_866)
            XCTAssertEqual(context["source"] as? String, "offline")
            XCTAssertEqual(context["localBytes"] as? Int, 1_024)
            guard let errors = context["nativeErrors"] as? [[String: Any]], !errors.isEmpty else { XCTFail("Actual native failure chain is required"); return }
            XCTAssertEqual(errors[0]["domain"] as? String, "AVFoundationErrorDomain")
            XCTAssertTrue([-11828, -11829].contains(errors[0]["code"] as? Int ?? 0))
        }
        attachPlayback43("invalid-offline")
        mainTabButton("我").tap()
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 5))
        let diagnosticsLink = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本机错误与诊断记录")).firstMatch
        for _ in 0..<6 {
            if diagnosticsLink.exists && diagnosticsLink.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(diagnosticsLink.exists && diagnosticsLink.isHittable)
        diagnosticsLink.tap()
        XCTAssertTrue(app.navigationBars["本机诊断记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "作品 #146853866")).firstMatch.exists)
        attachScreenshot(named: "playback43-diagnostics-native-codes")
    }
    func testPlaybackDiagnostics46CurrentTargetRetainsNativeFailure() {
        launchPlayback43("invalid-current-target")
        waitUntil("Both native failure attempts for the newly confirmed work must persist", timeout: 15) {
            self.playback43Entries().compactMap { $0["playback"] as? [String: Any] }.count == 2
        }
        let contexts = playback43Entries().compactMap { $0["playback"] as? [String: Any] }
        XCTAssertEqual(Set(contexts.compactMap { $0["attempt"] as? Int }), [0, 1])
        for context in contexts {
            XCTAssertEqual(context["workID"] as? Int, 146_853_737)
            XCTAssertEqual(context["source"] as? String, "offline")
            XCTAssertEqual(context["localBytes"] as? Int, 1_024)
            guard let errors = context["nativeErrors"] as? [[String: Any]], !errors.isEmpty else {
                XCTFail("Actual native failure chain is required for the new target"); return
            }
            XCTAssertEqual(errors[0]["domain"] as? String, "AVFoundationErrorDomain")
            XCTAssertTrue([-11828, -11829].contains(errors[0]["code"] as? Int ?? 0))
        }
        attachPlayback43("invalid-current-target")
    }

    func testPlaybackDiagnostics43BadCacheRecordsActualSourceThenRecovers() {
        launchPlayback43("bad-cache")
        waitUntil("Actual corrupt cache failure must be recorded", timeout: 12) { !self.playback43Entries().isEmpty }
        waitPlayingFixture()
        let contexts = playback43Entries().compactMap { $0["playback"] as? [String: Any] }
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0]["source"] as? String, "cache")
        XCTAssertEqual(contexts[0]["localBytes"] as? Int, 1_024)
        XCTAssertEqual(contexts[0]["attempt"] as? Int, 0)
        XCTAssertEqual(playerFields()["created"], "2")
        XCTAssertEqual(playerFields()["muted"], "true")
        attachPlayback43("bad-cache")
    }
    func testPlaybackDiagnostics43UntargetedFailureKeepsNoWorkID() {
        launchPlayback43("invalid-untargeted")
        waitUntil("An ordinary generic failure should still be recorded", timeout: 12) { !self.playback43Entries().isEmpty }
        XCTAssertTrue(playback43Entries().allSatisfy { $0["playback"] == nil })
        attachPlayback43("invalid-untargeted")
    }

    func testVideoFooterAndCompactTabsStayStable() {
        visualLaunch(width: 0, large: false, landscape: false)
        app.segmentedControls["timeline.media-kind"].buttons["视频"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let favorite = visualButton("favorite-28037102")
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        let follow = visualButton("follow-28037901")
        XCTAssertTrue(follow.waitForExistence(timeout: 8))
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10)); XCTAssertTrue(seek.isHittable)
        let before = seek.frame
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable })!
        let rotate = app.buttons["手动切换横竖屏"]
        visualAssertBareActions(itemID: 28_037_102, caseName: "video-portrait")
        XCTAssertEqual(seek.frame.height, 44, accuracy: 1)
        XCTAssertEqual(seek.frame.minY, rotate.frame.maxY, accuracy: 1)
        XCTAssertTrue(app.buttons["取消静音"].isHittable)
        let deck = heightDeck().frame
        let tap = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX, dy: deck.minY + 130))
        // One raw read per stage; no extra readiness waits or diagnostic UI
        // queries are inserted into the original seek-to-resume sequence.
        let initialPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        tap.tap(); RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let paused = seekSeconds(seek.valueDescription)!
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(seekSeconds(seek.valueDescription)!, paused, accuracy: 0.5, "The media tap must actually pause playback")
        XCTAssertEqual(seek.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(rotate.frame.maxY, before.minY, accuracy: 1)
        attachScreenshot(named: "controls39-video-paused")
        let pausedPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let nearHalf = NSPredicate { _, _ in abs((self.seekSeconds(seek.valueDescription) ?? -100) - 15) < 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: nearHalf, object: nil)], timeout: 5), .completed)
        let soughtPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        tap.tap()
        let playing = NSPredicate { _, _ in (self.seekSeconds(seek.valueDescription) ?? 0) >= 16 }
        let growthResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 4)
        let finalPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        // Detailed UI queries and the new screenshot occur only after the
        // unchanged four-second observation window has finished.
        for (phase, raw) in [("before-pause", initialPlayerRaw), ("paused-before-seek", pausedPlayerRaw),
                             ("seek-before-resume", soughtPlayerRaw), ("after-original-growth-window", finalPlayerRaw)] {
            print("FOOTER40_FAST phase=\(phase);\(raw)")
        }
        let currentPage = app.descendants(matching: .any).matching(identifier: "media-page-28037102").firstMatch
        let scopedSeek = currentPage.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        let scopedReceipt = scopedSeek.exists ? "value=\(scopedSeek.valueDescription),frame=\(scopedSeek.frame),hittable=\(scopedSeek.isHittable)" : "not-exposed"
        let finalFocus = watchFocus()
        print("FOOTER40_FAST_UI result=\(growthResult);globalSeek={value=\(seek.valueDescription),frame=\(seek.frame),hittable=\(seek.isHittable)};scopedSeek={\(scopedReceipt)};focus=\(finalFocus);capturedDeck=\(deck);tap=(\(deck.midX),\(deck.minY + 130))")
        attachScreenshot(named: "footer40-fast-after-original-growth-window")
        XCTAssertEqual(growthResult, .completed, "The original progress label must reach 16 seconds within its original four-second window")
        XCTAssertEqual(seek.frame.minY, before.minY, accuracy: 1)
        let snapshots = [initialPlayerRaw, pausedPlayerRaw, soughtPlayerRaw, finalPlayerRaw].map { qaFields($0) }
        var parsed: [(taps: Int, seeks: Int, position: Double, rate: Double)] = []
        for (index, fields) in snapshots.enumerated() {
            guard let playerID = fields["player"], playerID != "none", !playerID.isEmpty,
                  let taps = fields["taps"].flatMap(Int.init), let seeks = fields["seekStarts"].flatMap(Int.init),
                  let position = fields["position"].flatMap(Double.init), position.isFinite,
                  let rate = fields["rate"].flatMap(Double.init), rate.isFinite,
                  fields["created"] != nil, fields["prepare"] != nil, fields["muted"] != nil, fields["rateHolds"] != nil else {
                XCTFail("Missing or invalid actual player QA fields at stage \(index): \(fields)"); return
            }
            parsed.append((taps, seeks, position, rate))
        }
        XCTAssertEqual(parsed[0].rate, 1, "Observe whether the original setup was actually playing before the pause tap")
        XCTAssertEqual(parsed[1].taps, parsed[0].taps + 1, "One actual pause tap must execute exactly one accepted playback callback")
        XCTAssertEqual(parsed[1].rate, 0)
        XCTAssertEqual(parsed[2].taps, parsed[1].taps, "The progress-bar tap must not toggle playback")
        XCTAssertEqual(parsed[2].seeks, parsed[1].seeks + 1, "The actual bar tap must begin exactly one seek")
        XCTAssertEqual(parsed[2].rate, 0, "Seeking while paused must keep actual playback paused")
        XCTAssertLessThan(abs(parsed[2].position - 15), 2, "Compare completed actual seek position with the original label check")
        XCTAssertEqual(parsed[3].taps, parsed[2].taps + 1, "One actual resume tap must execute exactly one accepted playback callback")
        XCTAssertEqual(parsed[3].rate, 1)
        XCTAssertEqual(parsed[3].seeks, parsed[2].seeks, "The resume tap must not begin a seek")
        XCTAssertGreaterThanOrEqual(parsed[3].position, parsed[2].position + 1, "Actual playback must advance during the original progress observation")
        for fields in snapshots.dropFirst() {
            for key in ["player", "created", "prepare", "muted", "rateHolds"] {
                XCTAssertEqual(fields[key], snapshots[0][key], "Footer actions must preserve actual \(key)")
            }
        }
        XCTAssertEqual(snapshots[3]["muted"], "true")
        XCTAssertEqual(finalFocus, 28_037_102)
        let tabs = mainTabBar()
        XCTAssertTrue(tabs.exists); XCTAssertEqual(["main.tab.timeline", "main.tab.2", "main.tab.4", "main.tab.3"].filter { tabs.buttons.matching(identifier: $0).count > 0 }.count, 4)
        XCTAssertLessThanOrEqual(tabs.frame.height, 54)
        for title in ["作者榜", "搜索", "我", "时间线"] {
            let button = mainTabButton(title); XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44); button.tap()
            switch title {
            case "作者榜": XCTAssertTrue(app.navigationBars["作者榜"].waitForExistence(timeout: 5))
            case "搜索": XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
            case "我": XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 5))
            default: XCTAssertTrue(app.segmentedControls["timeline.media-kind"].waitForExistence(timeout: 5))
            }
        }
        heightAssert("recommendation", phase: "controls39-video-after-tabs", expected: 28_037_102)
        attachScreenshot(named: "controls39-video-playing-compact-tabs")
        print("CONTROLS39_FOOTER seek44, no-gap slot, stable paused/playing geometry, actual seek and4tab clicks passed")
        app.terminate()
    }

    func testVideoLargeLandscapeControlsStayInsideViewport() {
        visualLaunch(width: 0, large: true, landscape: false)
        app.segmentedControls["timeline.media-kind"].buttons["视频"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        visualEnsureLandscape()
        let favorite = visualButton("favorite-28037102"), follow = visualButton("follow-28037901")
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10)); XCTAssertTrue(seek.isHittable)
        let deck = heightDeck().frame
        XCTAssertGreaterThan(deck.width, deck.height)
        XCTAssertGreaterThanOrEqual(favorite.frame.minY, deck.minY + 92 - 1,
                                    "Compact landscape controls must use the 92pt chrome reservation")
        for button in [favorite, follow] {
            XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minY, deck.minY); XCTAssertLessThanOrEqual(button.frame.maxY, seek.frame.minY + 1)
        }
        visualAssertBareActions(itemID: 28_037_102, caseName: "video-large-landscape")
        XCTAssertEqual(seek.frame.height, 44, accuracy: 1)
        XCTAssertLessThanOrEqual(seek.frame.maxY, deck.maxY + 1)
        XCTAssertTrue(app.buttons["取消静音"].isHittable)
        heightAssert("recommendation", phase: "controls39-large-video-landscape", expected: 28_037_102)
        let slots = ["时间线", "作者榜", "搜索", "我"].map { mainTabButton($0).frame }
        for index in 0..<slots.count {
            XCTAssertEqual(slots[index].width, slots[0].width, accuracy: 1)
            if index > 0 { XCTAssertLessThanOrEqual(slots[index - 1].maxX, slots[index].minX + 1) }
        }
        attachScreenshot(named: "controls39-video-large-landscape")
        print("CONTROLS39_LARGE_VIDEO actualViewport=\(deck);seek=\(seek.frame);favorite=\(favorite.frame);follow=\(follow.frame);muted=true")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }

    private func visualLaunch(width: Int, large: Bool, landscape: Bool, state: String? = nil, extra: [String] = []) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls"]
        app.launchArguments += extra
        if let state { app.launchArguments += ["--qa-control-state=\(state)"] }
        if width > 0 { app.launchArguments += ["--qa-control-width=\(width)"] }
        if large { app.launchArguments += ["--qa-control-large-type", "--qa-control-long-author"] }
        app.launchArguments += ["-app.appearance", width == 375 ? "dark" : "light"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let mode = app.buttons["timeline.presentation"]; XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.valueDescription.contains("双列网格") { mode.tap() }
        heightCloseNotices()
        app.segmentedControls["timeline.media-kind"].buttons["全部"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let favoriteReady = visualButton("favorite-28037100").waitForExistence(timeout: 10)
        if !favoriteReady { attachScreenshot(named: "controls39-missing-favorite"); print(String(app.debugDescription.prefix(18000))) }
        XCTAssertTrue(favoriteReady)
        XCTAssertTrue(visualButton("follow-28037901").waitForExistence(timeout: 10))
        if landscape { visualEnsureLandscape() }
    }

    private func visualEnsureLandscape() {
        let frame = heightDeck().frame
        if frame.width <= frame.height {
            let active = app.buttons.matching(NSPredicate(format: "label == %@", "手动切换横竖屏")).allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertEqual(active.count, 1, "Only the currently visible lane may supply the rotation action")
            guard let rotate = active.first else { return }
            rotate.tap(); heightWaitOrientation(landscape: true)
        }
        let stable = NSPredicate { _, _ in let frame = self.heightDeck().frame; return frame.width > frame.height && frame.height > 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 5), .completed)
    }

    private func visualTypeControls(caseName: String) {
        let picker = app.segmentedControls["timeline.media-kind"]
        let filter = app.buttons.matching(identifier: "timeline.filter").firstMatch
        let row = app.staticTexts["qa.controls.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let original = app.staticTexts["qa.controls.filter"].valueDescription.components(separatedBy: ";").dropFirst().joined(separator: ";")
        for (title, raw) in [("图片", "image"), ("视频", "video"), ("全部", "all")] {
            // This SDK reports legacy Button aliases for native segment labels.
            // Tap the measured visible segment, then verify actual app selection.
            picker.buttons[title].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(picker.buttons[title].isSelected)
            if caseName.hasPrefix("landscape") { visualEnsureLandscape() }
            let values = heightValues(row.valueDescription)
            guard let rowX = values["x"], let rowWidth = values["w"] else { XCTFail("Unparseable actual control frame: \(row.valueDescription)"); return }
            let center = rowX + rowWidth / 2
            XCTAssertEqual(picker.frame.midX, center, accuracy: 0.75)
            XCTAssertGreaterThanOrEqual(picker.frame.minX, values["x"]! - 1)
            XCTAssertGreaterThanOrEqual(filter.frame.minX - picker.frame.maxX, 10)
            XCTAssertLessThanOrEqual(filter.frame.maxX, values["x"]! + values["w"]! + 1)
            let segments = ["图片", "全部", "视频"].map { picker.buttons[$0] }
            print("CONTROLS39_SEGMENTS selected=\(raw);" + segments.map { "\($0.label):\($0.frame):hit=\($0.isHittable)" }.joined(separator: ";"))
            for segment in segments {
                XCTAssertEqual(segment.frame.width, picker.frame.width / 3, accuracy: 1.5)
                XCTAssertEqual(segment.frame.midY, picker.frame.midY, accuracy: 1)
            }
            let state = app.staticTexts["qa.controls.filter"].valueDescription
            XCTAssertTrue(state.hasPrefix("kind=\(raw);")); XCTAssertEqual(state.components(separatedBy: ";").dropFirst().joined(separator: ";"), original)
            print("CONTROLS39_TYPE case=\(caseName);selected=\(raw);picker=\(picker.frame);contentCenter=\(center);filter=\(filter.frame)")
            attachScreenshot(named: "controls39-\(caseName)-type-\(raw)")
        }
        filter.tap(); XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        if caseName.hasPrefix("landscape") { visualEnsureLandscape() }
        XCTAssertTrue(picker.buttons["全部"].isSelected)
    }

    private func visualSocialStates(caseName: String) {
        visualAssertSocial(caseName: caseName, saved: false, followed: false)
        visualButton("follow-28037901").tap(); visualAssertSocial(caseName: caseName, saved: false, followed: true)
        visualSaveFavorite(remove: false); visualAssertSocial(caseName: caseName, saved: true, followed: true)
        visualButton("follow-28037901").tap(); visualAssertSocial(caseName: caseName, saved: true, followed: false)
        visualSaveFavorite(remove: true); visualAssertSocial(caseName: caseName, saved: false, followed: false)
    }
    private func visualSaveFavorite(remove: Bool) {
        visualButton("favorite-28037100").tap()
        XCTAssertTrue(app.navigationBars["收藏图片"].waitForExistence(timeout: 5))
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        if remove { folder.tap() }
        let save = app.buttons["保存"]; XCTAssertTrue(save.isEnabled)
        attachScreenshot(named: "controls39-favorite-editor")
        save.tap()
        XCTAssertTrue(app.navigationBars["收藏图片"].waitForNonExistence(timeout: 5))
    }
    private func visualAssertSocial(caseName: String, saved: Bool, followed: Bool) {
        if caseName.hasPrefix("landscape") { visualEnsureLandscape() }
        let favorite = visualButton("favorite-28037100"), follow = visualButton("follow-28037901")
        let savedTitle = saved ? "已收藏" : "收藏", followTitle = followed ? "已关注" : "关注"
        let labelsReady = NSPredicate { _, _ in favorite.label.contains(savedTitle) && follow.label.contains(followTitle) }
        let labelResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: labelsReady, object: nil)], timeout: 5)
        if labelResult != .completed {
            attachScreenshot(named: "controls39-social-label-failure")
            print("CONTROLS39_LABELS favorite=\(favorite.label);value=\(favorite.valueDescription);follow=\(follow.label);value=\(follow.valueDescription)")
            print(String(app.debugDescription.suffix(14000)))
        }
        XCTAssertEqual(labelResult, .completed)
        XCTAssertEqual(favorite.label.contains("已收藏"), saved); XCTAssertEqual(follow.label.contains("已关注"), followed)
        visualAssertBareActions(itemID: 28_037_100, caseName: caseName)
        print("CONTROLS40_SOCIAL case=\(caseName);saved=\(saved);followed=\(followed);favorite=\(favorite.frame);follow=\(follow.frame)")
        attachScreenshot(named: "controls39-\(caseName)-saved\(saved)-followed\(followed)")
    }
    private func visualAssertBareActions(itemID: Int, caseName: String) {
        let favorite = visualButton("favorite-\(itemID)")
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable })!
        let follow = visualButton("follow-28037901")
        let deck = heightDeck().frame
        for button in [favorite, details] {
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.frame.width, 44, accuracy: 1); XCTAssertEqual(button.frame.height, 44, accuracy: 1)
            XCTAssertGreaterThan(button.frame.midX, deck.midX)
            XCTAssertGreaterThanOrEqual(button.frame.minY, deck.minY); XCTAssertLessThanOrEqual(button.frame.maxY, deck.maxY + 1)
        }
        XCTAssertEqual(favorite.frame.midX, details.frame.midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(details.frame.minY - favorite.frame.maxY, 0)
        XCTAssertLessThanOrEqual(details.frame.minY - favorite.frame.maxY, 8)
        XCTAssertFalse(app.staticTexts["VIDEO"].exists); XCTAssertFalse(app.staticTexts["IMAGE"].exists)
        let geometries = app.staticTexts.matching(identifier: "collection.qa.geometry")
        let geometry = geometries.allElementsBoundByIndex.first { Int(heightValues($0.valueDescription)["focused"] ?? 0) == itemID }!
        let values = heightValues(geometry.valueDescription)
        guard let ax = values["authorX"], let aw = values["authorW"], let ay = values["authorY"], let ah = values["authorH"],
              let fx = values["followX"], let fy = values["followY"], let fh = values["followH"] else { XCTFail("Missing actual author/follow frames: \(geometry.valueDescription)"); return }
        XCTAssertGreaterThanOrEqual(fx - (ax + aw), -1); XCTAssertLessThanOrEqual(fx - (ax + aw), 16, "Follow must sit beside the author, without a flexible gap")
        XCTAssertEqual(ay + ah / 2, fy + fh / 2, accuracy: 1)
        XCTAssertGreaterThanOrEqual(follow.frame.height + 0.01, 44)
        if itemID == 28_037_100 {
            XCTAssertEqual(mainTabBar().frame.minY - follow.frame.maxY, 8, accuracy: 1,
                           "Image author/follow controls should sit only 8pt above the tabs")
        }
        if caseName.contains("largetrue") { XCTAssertGreaterThan(values["follow_textH"] ?? 0, 20, "The actual media host must receive A2") }
        print("CONTROLS40_BARE case=\(caseName);favorite=\(favorite.frame);details=\(details.frame);\(geometry.valueDescription)")
        attachScreenshot(named: "controls40-bare-\(caseName)")
    }

    func testVisualControlsBusyAndUnknownStates() {
        for state in ["busy", "unknown"] {
            visualLaunch(width: 320, large: true, landscape: false, state: state)
            let follow = visualButton("follow-28037901")
            if state == "busy" { XCTAssertFalse(follow.isEnabled) }
            else { XCTAssertTrue(follow.label.contains("待确认")) }
            XCTAssertTrue(visualButton("favorite-28037100").isHittable)
            attachScreenshot(named: "controls40-\(state)-long-author-A2")
            app.terminate()
        }
    }

    func testCentralLongPressPreservesVideoAndRestoresImageChrome() {
        visualLaunch(width: 0, large: false, landscape: false)
        app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let before = playerFields(), focus = watchFocus(), toggles = metric("toggles", in: chromeState().valueDescription)
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        guard let videoDetails = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("A visible video details control must exist before hiding"); return }
        attachScreenshot(named: "chrome40-video-before-hold")
        centralPress()
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        attachScreenshot(named: "chrome40-video-hidden")
        assertChromeNotHittable([mainTabBar(), mainTabButton("我"), app.segmentedControls["timeline.media-kind"],
                                visualButton("favorite-28037102"), videoDetails, seek], phase: "video-hidden")
        let hidden = playerFields(); assertUnchangedPlayer(before, hidden)
        XCTAssertEqual(watchFocus(), focus)
        waitUntil("Playback must advance while the actual chrome is hidden") { Double(self.playerFields()["position"] ?? "0")! > Double(before["position"] ?? "0")! + 0.5 }
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), toggles + 1)
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        assertUnchangedPlayer(before, playerFields()); XCTAssertEqual(watchFocus(), focus)
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), toggles + 2)
        XCTAssertTrue(mainTabButton("我").isHittable); XCTAssertTrue(visualButton("favorite-28037102").isHittable)
        app.segmentedControls["timeline.media-kind"].buttons["图片"].tap()
        XCTAssertTrue(visualButton("favorite-28037100").waitForExistence(timeout: 8))
        let imageFocus = watchFocus()
        let favorite = visualButton("favorite-28037100")
        guard let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("A visible image details control must exist before hiding"); return }
        let me = mainTabButton("我"), picker = app.segmentedControls["timeline.media-kind"]
        let regions = ["favorite": favorite.frame.insetBy(dx: 8, dy: 8), "details": details.frame.insetBy(dx: 8, dy: 8),
                       "header": picker.frame.insetBy(dx: 4, dy: 4), "bottom-tabs": me.frame.insetBy(dx: 4, dy: 4)]
        let originalFrames = [favorite.frame, details.frame, me.frame]
        let imageBefore = captureChromePixels(named: "chrome40-image-before-hold")
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        let imageHidden = captureChromePixels(named: "chrome40-image-hidden")
        assertChromeNotHittable([favorite, details, me, mainTabBar(), picker], phase: "image-hidden")
        assertChromePixelsDisappear(before: imageBefore, hidden: imageHidden, regions: regions)
        XCTAssertEqual(watchFocus(), imageFocus)
        // Static image taps isolate hidden controls from a video's intentional
        // single-tap pause. These are real taps at the formerly visible targets.
        for frame in originalFrames {
            tapScreenFrame(frame)
            XCTAssertFalse(app.navigationBars["收藏图片"].exists)
            XCTAssertFalse(app.navigationBars["作品详情"].exists)
            XCTAssertFalse(app.navigationBars["账号与设置"].exists)
            XCTAssertTrue(chromeState().valueDescription.contains("hidden=true"))
            XCTAssertEqual(watchFocus(), imageFocus)
        }
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        XCTAssertTrue(favorite.isHittable); XCTAssertEqual(watchFocus(), imageFocus)
        attachScreenshot(named: "chrome40-image-restored")
        mainTabButton("我").tap(); XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabBar().isHittable)
    }

    func testCentralPressPreservesActualVideoGeometryAcrossLayouts() {
        let cases: [(name: String, width: Int, large: Bool, landscape: Bool, extra: [String])] = [
            ("normal-portrait", 0, false, false, []),
            ("narrow320-A2", 320, true, false, []),
            ("landscape", 0, false, true, []),
            ("landscape-A2", 0, true, true, []),
            ("wide-video", 0, false, false, ["--qa-wide-video"])
        ]

        for item in cases {
            visualLaunch(width: item.width, large: item.large, landscape: item.landscape,
                         extra: ["--qa-chrome-geometry"] + item.extra)
            app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
            waitPlayingFixture()
            if item.landscape { visualEnsureLandscape(); waitPlayingFixture() }
            let beforePlayer = playerFields()
            waitUntil("Actual player surface must be ready and expose nonempty video geometry") {
                self.videoGeometryReadback() != nil
            }
            guard let before = videoGeometryReadback() else {
                XCTFail("Missing valid video geometry before hold in \(item.name)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            layout41LogGeometry(item.name, phase: "visible", readback: before.raw)
            assertVideoGeometryOrientation(before.fields, landscape: item.landscape)
            attachScreenshot(named: "layout41-\(item.name)-chrome-visible")

            centralPress()
            XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
            waitUntil("Muted local video must keep advancing with chrome hidden") {
                guard let start = beforePlayer["position"].flatMap(Double.init),
                      let current = self.playerFields()["position"].flatMap(Double.init) else { return false }
                return current > start
            }
            waitUntil("Hidden chrome must retain a ready actual player surface") { self.videoGeometryReadback() != nil }
            guard let hidden = videoGeometryReadback() else {
                XCTFail("Missing valid video geometry while hidden in \(item.name)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            layout41LogGeometry(item.name, phase: "hidden", readback: hidden.raw)
            assertVideoGeometryOrientation(hidden.fields, landscape: item.landscape)
            attachScreenshot(named: "layout41-\(item.name)-chrome-hidden")
            assertVideoGeometryUnchanged(before.fields, hidden.fields, phase: "hidden/\(item.name)")
            let hiddenPlayer = playerFields()
            assertChromePlayerIdentityUnchanged(beforePlayer, hiddenPlayer, phase: "hidden/\(item.name)")
            guard let start = beforePlayer["position"].flatMap(Double.init),
                  let hiddenPosition = hiddenPlayer["position"].flatMap(Double.init) else {
                XCTFail("Missing actual player positions before/hidden: \(beforePlayer), \(hiddenPlayer)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            XCTAssertGreaterThan(hiddenPosition, start, "Hidden chrome must not reset actual video progress")

            centralPress()
            XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
            waitUntil("Restored chrome must retain a ready actual player surface") { self.videoGeometryReadback() != nil }
            guard let restored = videoGeometryReadback() else {
                XCTFail("Missing valid video geometry after restore in \(item.name)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            layout41LogGeometry(item.name, phase: "restored", readback: restored.raw)
            assertVideoGeometryOrientation(restored.fields, landscape: item.landscape)
            attachScreenshot(named: "layout41-\(item.name)-chrome-restored")
            assertVideoGeometryUnchanged(before.fields, restored.fields, phase: "restored/\(item.name)")
            let restoredPlayer = playerFields()
            assertChromePlayerIdentityUnchanged(beforePlayer, restoredPlayer, phase: "restored/\(item.name)")
            guard let restoredPosition = restoredPlayer["position"].flatMap(Double.init) else {
                XCTFail("Missing actual restored player position: \(restoredPlayer)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            XCTAssertGreaterThanOrEqual(restoredPosition, hiddenPosition,
                                        "Restoring chrome must not rewind actual playback")
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testVideoActionRailSocialFooterAndSeekRemainUsable() {
        // CollectionPagingQA.prepare() validates its bundled test video has no audio track.
        visualLaunch(width: 0, large: false, landscape: false)
        app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()

        let favorite = visualButton("favorite-28037102")
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch
        let mute = app.buttons["取消静音"]
        let rotate = app.buttons["手动切换横竖屏"]
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        let follow = visualButton("follow-28037901")
        let author = app.buttons["media.author.28037102"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8)); XCTAssertTrue(details.exists)
        XCTAssertTrue(mute.isHittable); XCTAssertTrue(rotate.isHittable)
        XCTAssertTrue(follow.isHittable); XCTAssertTrue(author.isHittable); XCTAssertTrue(seek.isHittable)

        let rail = [favorite, details, mute, rotate]
        for (index, button) in rail.enumerated() {
            XCTAssertEqual(button.frame.width, 44, accuracy: 1, "Action \(index) should expose a 44pt target")
            XCTAssertEqual(button.frame.height, 44, accuracy: 1, "Action \(index) should expose a 44pt target")
            XCTAssertEqual(button.frame.midX, rail[0].frame.midX, accuracy: 1,
                           "Favorite/details/mute/rotation actions must share one right edge column")
            if index > 0 {
                XCTAssertEqual(button.frame.minY - rail[index - 1].frame.maxY, 8, accuracy: 1,
                               "The four right rail actions must keep 8pt vertical gaps")
            }
        }
        XCTAssertEqual(author.frame.midY, follow.frame.midY, accuracy: 1,
                       "Author and follow must stay adjacent on one social row")
        XCTAssertGreaterThanOrEqual(follow.frame.minX - author.frame.maxX, -1)
        XCTAssertLessThanOrEqual(follow.frame.minX - author.frame.maxX, 16)
        XCTAssertEqual(seek.frame.minY, rotate.frame.maxY, accuracy: 1,
                       "The right rail and seek targets should meet without an extra blank row")
        XCTAssertEqual(seek.frame.minY, follow.frame.maxY, accuracy: 1,
                       "The follow and seek targets should meet without overlapping")
        XCTAssertEqual(mainTabBar().frame.minY, seek.frame.maxY, accuracy: 1,
                       "The seek target must finish at the tabs without another bottom gap")
        for control in rail + [author, follow, seek] {
            XCTAssertTrue(control.isHittable, "Control must not overlap or be covered: \(control.identifier) \(control.frame)")
        }

        // CollectionPagingQA.prepare validates its bundled fixture has no audio track.
        mute.tap()
        XCTAssertTrue(app.buttons["静音"].waitForExistence(timeout: 4))
        XCTAssertEqual(playerFields()["muted"], "false")
        app.buttons["静音"].tap()
        XCTAssertTrue(app.buttons["取消静音"].waitForExistence(timeout: 4))
        XCTAssertEqual(playerFields()["muted"], "true")

        rotate.tap(); heightWaitOrientation(landscape: true)
        app.buttons["手动切换横竖屏"].tap(); heightWaitOrientation(landscape: false)

        let followLabelBefore = follow.label
        follow.tap()
        waitUntil("The fake follow action must publish its followed label") { follow.label.contains("已关注") }
        follow.tap()
        waitUntil("The fake follow action should be reversible") { follow.label == followLabelBefore }

        favorite.tap()
        XCTAssertTrue(app.navigationBars["收藏视频"].waitForExistence(timeout: 5), "Open the local QA favorite editor")
        let cancelFavorite = app.buttons["取消"]
        XCTAssertTrue(cancelFavorite.waitForExistence(timeout: 5)); cancelFavorite.tap()
        XCTAssertTrue(app.navigationBars["收藏视频"].waitForNonExistence(timeout: 5))

        details.tap()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "details.summary").firstMatch.waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForNonExistence(timeout: 5))

        let beforeSeek = seek.valueDescription
        guard let beforeSeconds = seekSeconds(beforeSeek) else {
            XCTFail("Cannot parse seek progress before tap: \(beforeSeek)"); return
        }
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitUntil("Actual seek should land near 15s, half of the 30-second QA clip") {
            abs((self.seekSeconds(seek.valueDescription) ?? -100) - 15) < 2
        }
        guard let afterSeconds = seekSeconds(seek.valueDescription) else {
            XCTFail("Cannot parse seek progress after tap: \(seek.valueDescription)"); return
        }
        XCTAssertLessThan(abs(afterSeconds - 15), 2)
    }

    func testStyle48SearchTagsAndAuthorFilterInBothAppearances() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-style48"]
        app.launch()
        for appearance in ["深色", "浅色"] {
            mainTabButton("我").tap(); chooseAppearance(appearance)
            mainTabButton("搜索").tap()
            let field = app.textFields["search-title-input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            attachScreenshot(named: "style48-\(appearance)-combined-search")
            let picker = app.buttons["search-tag-picker"]
            XCTAssertTrue(picker.isHittable); picker.tap()
            XCTAssertTrue(app.textFields["tag-search-input"].waitForExistence(timeout: 5))
            let portrait = app.buttons["tag-directory.tag.42001"]
            let night = app.buttons["tag-directory.tag.42002"]
            XCTAssertTrue(portrait.waitForExistence(timeout: 5)); XCTAssertTrue(night.exists)
            XCTAssertGreaterThanOrEqual(portrait.frame.height, 44)
            if !portrait.valueDescription.contains("已选择") { portrait.tap() }
            if !night.valueDescription.contains("已选择") { night.tap() }
            XCTAssertTrue(portrait.valueDescription.contains("已选择"))
            XCTAssertTrue(night.valueDescription.contains("已选择"))
            attachScreenshot(named: "style48-\(appearance)-tag-selection")
            app.buttons["完成"].tap()
            XCTAssertTrue(app.buttons["移除搜索标签 portrait"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["移除搜索标签 night"].exists)
            XCTAssertTrue(app.buttons["search-submit"].isEnabled)
            attachScreenshot(named: "style48-\(appearance)-combined-selected")

            mainTabButton("作者榜").tap()
            XCTAssertTrue(app.segmentedControls.buttons["Seasonal"].waitForExistence(timeout: 5))
            let recent = app.buttons["leaderboard.recent-filter"]
            XCTAssertTrue(recent.isHittable); XCTAssertGreaterThanOrEqual(recent.frame.height, 44)
            attachScreenshot(named: "style48-\(appearance)-author-board")
            recent.tap()
            XCTAssertTrue(app.buttons["近 7 天"].waitForExistence(timeout: 5))
            attachScreenshot(named: "style48-\(appearance)-author-time-menu")
            app.buttons["不限时间"].tap()
        }
    }

    func testDetailsTagsCompactExpansionSelectionAndSearchNavigation() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags"])
        app.segmentedControls["timeline.media-kind"].buttons["视频"].tap()
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 8)); details.tap()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 5))
        let summary = app.staticTexts.matching(identifier: "details.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Use the source Text accessibility identifier for the compact summary")
        let more = app.buttons["details.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertTrue(more.label.contains("更多作者操作"))

        let search = app.buttons["details.search"]
        XCTAssertFalse(search.exists, "No disabled footer occupies space before any tag is selected")
        XCTAssertTrue(app.descendants(matching: .any)["details.preview"].exists, "Details should include a static work preview")
        XCTAssertFalse(app.buttons["清空"].exists, "Clear appears only once selection exists")
        let count = app.staticTexts["details.selection.count"]
        XCTAssertTrue(count.exists); XCTAssertTrue(count.label.contains("0 / 8"))
        attachScreenshot(named: "layout41-details-collapsed")

        let expectedTags = ["portrait", "night", "city", "street fashion", "soft lighting", "cinematic",
                            "rain", "architecture", "neon signs", "reflection", "evening", "long coat",
                            "urban landscape", "depth of field", "warm window light", "35mm photo", "blue hour", "city walk"]
        let expand = app.buttons["details.tags.expand"]
        let detailsScroll = app.scrollViews.firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "Neutral fixture should expose the full 18-tag set")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "details.tags").firstMatch.exists)
        XCTAssertTrue(layout41ScrollToHittable(expand, in: detailsScroll, towardBottom: true))
        expand.tap()
        for tag in expectedTags {
            XCTAssertTrue(app.buttons["details.tag.\(tag)"].exists, "Missing independent fixture tag: \(tag)")
        }
        // MediaDetailsView keeps its established sorted tag order; this final
        // alphabetic fixture tag lies beyond the collapsed first twelve.
        let farTagName = "warm window light"
        let farTag = app.buttons["details.tag.\(farTagName)"]
        XCTAssertTrue(layout41ScrollToHittable(farTag, in: detailsScroll, towardBottom: true),
                      "The last expanded tag must be scrolled into view before tapping")
        print("DETAILS41_TAG id=\(farTag.identifier);label=\(farTag.label);value=\(farTag.valueDescription);frame=\(farTag.frame)")
        farTag.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        print("DETAILS41_SELECTION count=\(count.label);tag=\(farTag.valueDescription)")
        waitUntil("The first visible chip must update both its selection and the count label") {
            count.label.contains("1 / 8") && farTag.valueDescription.contains("已选入组合搜索")
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(search.frame.height, 44)
        XCTAssertLessThanOrEqual(search.frame.height, 56, "Search affordance should remain compact")
        XCTAssertLessThanOrEqual(search.label.count, 15, "The compact footer should use short copy")

        XCTAssertTrue(layout41ScrollToHittable(expand, in: detailsScroll, towardBottom: true))
        expand.tap()
        let retainedTag = app.buttons["details.tag.\(farTagName)"]
        XCTAssertTrue(retainedTag.exists, "Selected tag after first twelve must remain visible when collapsed")
        XCTAssertTrue(layout41ScrollToHittable(retainedTag, in: detailsScroll, towardBottom: true))
        XCTAssertTrue(retainedTag.label == farTagName)

        let secondTag = app.buttons["details.tag.\(expectedTags[0])"]
        XCTAssertTrue(layout41ScrollToHittable(secondTag, in: detailsScroll, towardBottom: false),
                      "The first collapsed tag must remain reachable")
        secondTag.tap()
        waitUntil("Both visible tag selections must update the count label") { count.label.contains("2 / 8") }
        XCTAssertTrue(app.buttons["清空"].exists)
        attachScreenshot(named: "layout41-details-two-tags-selected")
        search.tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除搜索标签 ")).count, 2,
                       "Both selected real tags should navigate as initial AND criteria")
        XCTAssertTrue(app.buttons["search-submit"].exists)
        attachScreenshot(named: "layout41-details-combined-search")
    }

    func testCentralHoldGesturePrioritiesAndFullscreenExit() {
        visualLaunch(width: 0, large: false, landscape: false)
        app.segmentedControls["timeline.media-kind"].buttons["视频"].tap(); waitPlayingFixture()
        let before = playerFields(), initialToggles = metric("toggles", in: chromeState().valueDescription)
        let deck = heightDeck().frame
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX, dy: deck.midY))
        center.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX + 50, dy: deck.midY)))
        waitUntil("A short moved press must seek and cancel the central hold") { Int(self.playerFields()["seekStarts"] ?? "-1")! > Int(before["seekStarts"] ?? "-1")! }
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), initialToggles)
        center.tap(); waitUntil("Normal center tap pauses") { self.playerFields()["rate"] == "0.0" }
        let paused = playerFields(); RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(Double(playerFields()["position"]!)!, Double(paused["position"]!)!, accuracy: 0.3)
        center.tap(); waitPlayingFixture()
        let beforeEdge = playerFields()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.minX + 15, dy: deck.midY)).press(forDuration: 0.7)
        waitUntil("The edge hold must reach the original 2x callback") { Int(self.playerFields()["rateHolds"] ?? "-1")! == Int(beforeEdge["rateHolds"] ?? "-1")! + 1 }
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), initialToggles)
        XCTAssertEqual(playerFields()["taps"], beforeEdge["taps"]); XCTAssertEqual(playerFields()["rate"], "1.0")
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitUntil("The real progress control must still seek near 15 seconds") { abs((Double(self.playerFields()["position"] ?? "0") ?? 0) - 15) < 2 }
        center.doubleTap(); XCTAssertTrue(app.navigationBars["作者作品"].waitForExistence(timeout: 8))
        XCTAssertTrue(mainTabBar().isHittable, "Author navigation must restore ordinary navigation")
        mainTabButton("我").tap(); app.buttons["我的收藏"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        let card = app.buttons["media.grid.cell.28037100"]; XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap()
        let close = app.buttons["关闭作品"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let closeFrame = close.frame, fullscreenFocus = watchFocus()
        let fullscreenBefore = captureChromePixels(named: "chrome40-fullscreen-before-hold")
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        let fullscreenHidden = captureChromePixels(named: "chrome40-fullscreen-hidden")
        assertChromeNotHittable([close], phase: "fullscreen-hidden")
        assertChromePixelsDisappear(before: fullscreenBefore, hidden: fullscreenHidden,
                                   regions: ["fullscreen-close": closeFrame.insetBy(dx: 8, dy: 8)])
        tapScreenFrame(closeFrame)
        XCTAssertTrue(chromeState().valueDescription.contains("hidden=true"))
        XCTAssertEqual(watchFocus(), fullscreenFocus, "A tap at the hidden close button must keep the viewer open")
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        XCTAssertTrue(close.isHittable)
        close.tap(); XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabBar().isHittable)
        attachScreenshot(named: "chrome40-fullscreen-exit-navigation-restored")
    }

    func testAutomaticAppearanceFillMaintainsSixUpcomingAcrossSparsePages() {
        launchContinuation("sparse-reserve")
        XCTAssertTrue(app.staticTexts["continuation.qa.state"].waitForExistence(timeout: 5))
        waitUntil("Visible first video should immediately request its first fill page") {
            self.continuationFields()["requests"] == "2" && self.continuationFields()["gate"] == "waiting"
        }
        XCTAssertEqual(watchFocus(), 28_037_102, "Appearance fill must not move focus from the first video")
        XCTAssertEqual(continuationFields()["first"], "1")
        XCTAssertEqual(continuationFields()["lastCursor"], "scan-0")
        waitPlayingFixture()
        let beforePlayer = playerFields()

        releaseContinuationResponse()
        waitUntil("Appearance fill should cross sparse pages until six distinct upcoming works are available", timeout: 25) {
            self.continuationFields()["requests"] == "19" &&
                self.continuationFields()["returned"] == "28037306" &&
                self.continuationFields()["gate"] == "released"
        }
        XCTAssertEqual(watchFocus(), 28_037_102, "The focused initial video must stay selected during fill")
        XCTAssertEqual(continuationFields()["requests"], "19", "The reserve should stop after the exact eighteenth continuation")
        XCTAssertEqual(continuationFields()["returned"], "28037306")
        XCTAssertEqual(continuationFields()["lastCursor"], "scan-17", "The fixture observer exposes the nonempty final request cursor")
        assertUnchangedPlayer(beforePlayer, playerFields())
        guard let start = beforePlayer["position"].flatMap(Double.init),
              let finish = playerFields()["position"].flatMap(Double.init) else {
            XCTFail("Missing actual player progress around automatic fill")
            return
        }
        XCTAssertGreaterThan(finish, start, "Automatic fill must preserve active playback progress")
        assertNoFixtureRead(for: 1)
        attachScreenshot(named: "continuation41-appearance-fill-six-upcoming-sparse-pages")
    }

    func testPrefetch52UpdatesWindowAndResumesAfterTabSwitch() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["-mediaPrefetchCount", "6", "-wifiVideoPrefetch", "YES", "-muted", "YES"])
        let readback = app.descendants(matching: .any)["media.qa.prefetch"]
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 8), "All five available future fixture media should be ready, including locally cached videos")
        XCTAssertTrue(readback.valueDescription.contains("desired=5"))
        heightDeck().swipeUp()
        waitUntil("Paging updates the prefetch window without changing its scope") { self.watchFocus() == 28_037_101 }
        XCTAssertTrue(readback.waitForValueToContain("desired=4", timeout: 5))
        XCTAssertTrue(readback.waitForValueToContain("ready=4", timeout: 5))
        mainTabButton("我").tap()
        XCTAssertTrue(mainTabButton("时间线").waitForExistence(timeout: 5))
        mainTabButton("时间线").tap()
        waitUntil("Returning through the timeline button keeps its single-tap return-to-top behavior") { self.watchFocus() == 28_037_100 }
        XCTAssertTrue(readback.waitForValueToContain("pagingAllowed=false", timeout: 5), "The actual tab callback gates feed pagination after returning to the top")
        XCTAssertTrue(readback.waitForValueToContain("desired=5", timeout: 5))
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 8), "A retained viewer resumes media preloading at the requested top after hide")
        attachScreenshot(named: "prefetch53-window-resumed-at-top-after-tab-switch")
    }

    func testPrefetch53SingleTabTopKeepsKnownMediaWarmWithoutEnablingPaging() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["-mediaPrefetchCount", "6", "-wifiVideoPrefetch", "YES", "-muted", "YES"])
        let readback = app.descendants(matching: .any)["media.qa.prefetch"]
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 8))
        mainTabButton("时间线").tap()
        XCTAssertTrue(readback.waitForValueToContain("pagingAllowed=false", timeout: 5), "The programmatic-top gate still blocks automatic feed requests")
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 5), "Known media preloading remains enabled while feed paging is gated")
        XCTAssertEqual(watchFocus(), 28_037_100)
        attachScreenshot(named: "prefetch53-top-gate-keeps-known-window")
    }

    func testAutomaticContinuationSkipsEightFilteredPagesWithoutJump() {
        launchContinuation("filtered-empty")
        waitForAppearanceContinuation()
        let loading = app.descendants(matching: .any).matching(identifier: "feed.continuation.loading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 8))
        waitUntil("The current video must remain the active page while scanning") { self.watchFocus() == 28_037_102 }
        waitPlayingFixture()
        let before = playerFields()
        releaseContinuationResponse()
        waitUntil("Eight genuinely filtered pages must be crossed automatically", timeout: 20) { self.continuationFields()["requests"] == "10" && self.continuationFields()["returned"] == "28037104" }
        XCTAssertEqual(watchFocus(), 28_037_102, "Appending a matching video must not jump the current one")
        assertUnchangedPlayer(before, playerFields())
        XCTAssertFalse(app.buttons["继续加载"].exists); XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "media-page--1").firstMatch.exists)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "auto40-final-video", expected: 28_037_104)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feed.continuation.ended").firstMatch.waitForExistence(timeout: 5))
        assertNoFixtureRead(for: 0.8)
        attachScreenshot(named: "continuation40-eight-filtered-pages-real-end")
    }

    func testAutomaticContinuationInitialEmptyReachesRealEnd() {
        launchContinuation("initial-empty")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feed.continuation.loading").firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(continuationFields()["requests"], "2", "The actual initial scan must be waiting for its local response")
        attachScreenshot(named: "continuation40-initial-empty-loading-gated")
        releaseContinuationResponse()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feed.continuation.ended").firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(continuationFields()["requests"], "10")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "media-page-28037102").firstMatch.exists)
        assertNoFixtureRead(for: 0.8)
        attachScreenshot(named: "continuation40-initial-empty-to-real-end")
    }

    func testAutomaticContinuationRateLimitNeedsExplicitRetry() {
        launchContinuation("rate-limited")
        waitForAppearanceContinuation()
        releaseContinuationResponse()
        let retry = app.buttons["feed.continuation.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); XCTAssertFalse(retry.isEnabled, "429 must expose an actual cooldown")
        XCTAssertEqual(continuationFields()["requests"], "2"); XCTAssertEqual(continuationFields()["errors"], "1")
        assertNoFixtureRead(for: 0.8)
        waitUntil("Retry becomes enabled after the actual cooldown") { retry.isEnabled }
        XCTAssertEqual(continuationFields()["requests"], "2", "Cooldown expiry alone is not permission to retry")
        assertContinuationActionAccessible(retry)
        waitPlayingFixture()
        let before = playerFields(), focus = watchFocus()
        retry.tap()
        waitUntil("An explicit retry tap issues exactly one further page") { self.continuationFields()["requests"] == "3" && self.continuationFields()["returned"] == "28037104" }
        XCTAssertEqual(watchFocus(), focus)
        assertUnchangedPlayer(before, playerFields())
        waitUntil("Retry button tap must not pause the video") { (Double(self.playerFields()["position"] ?? "0") ?? 0) > (Double(before["position"] ?? "0") ?? 0) + 0.4 }
        attachScreenshot(named: "continuation40-explicit-retry-player-preserved")
    }

    func testAutomaticContinuationRepeatedCursorStaysStopped() {
        launchContinuation("repeated-cursor")
        waitPlayingFixture()
        XCTAssertEqual(watchFocus(), 28_037_102)
        waitUntil("Ordinary visible queue should automatically request continuation") {
            self.continuationFields()["requests"] == "2"
        }
        // Capture the production viewport before failure. Coordinate gestures
        // remain valid when a retained deck's XCTest role/hittability changes.
        let geometry = app.staticTexts.matching(identifier: "collection.qa.geometry").allElementsBoundByIndex.first {
            Int(heightValues($0.valueDescription)["focused"] ?? -1) == 28_037_102
        }
        let values = geometry.map { heightValues($0.valueDescription) } ?? [:]
        guard let x = values["viewportX"], let y = values["viewportY"],
              let width = values["viewportW"], let height = values["viewportH"], width > 0, height > 0 else {
            XCTFail("The actual initial media viewport must be measurable before the stalled response"); return
        }
        let viewport = CGRect(x: x, y: y, width: width, height: height)
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
        print("CONTINUATION40_STALL viewport=\(viewport)")
        lower.press(forDuration: 0.05, thenDragTo: upper)
        waitUntil("A real upward swipe must browse the second existing video") { self.watchFocus() == 28_037_104 }
        let restart = app.buttons["feed.continuation.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 8)); XCTAssertTrue(restart.isHittable)
        assertContinuationActionAccessible(restart)
        XCTAssertEqual(continuationFields()["requests"], "2")
        let focus = watchFocus()
        XCTAssertEqual(focus, 28_037_104)
        XCTAssertFalse(app.buttons["feed.continuation.retry"].exists)
        attachScreenshot(named: "continuation40-repeat-cursor-stalled-at-last")

        upper.press(forDuration: 0.05, thenDragTo: lower)
        waitUntil("The stalled error layer must allow a real swipe back to the first saved video") { self.watchFocus() == 28_037_102 }
        XCTAssertTrue(restart.isHittable); XCTAssertEqual(continuationFields()["requests"], "2")
        XCTAssertFalse(app.buttons["feed.continuation.retry"].exists)
        assertNoFixtureRead(for: 0.5)
        lower.press(forDuration: 0.05, thenDragTo: upper)
        waitUntil("The old queue must still allow a real swipe forward to the last video") { self.watchFocus() == 28_037_104 }
        XCTAssertTrue(restart.isHittable); XCTAssertEqual(continuationFields()["requests"], "2")
        assertNoFixtureRead(for: 0.5)
        lower.press(forDuration: 0.05, thenDragTo: upper)
        assertNoFixtureRead(for: 1)
        XCTAssertEqual(continuationFields()["requests"], "2")
        XCTAssertEqual(watchFocus(), focus); XCTAssertTrue(restart.isHittable)
        XCTAssertFalse(app.buttons["feed.continuation.retry"].exists)
        attachScreenshot(named: "continuation40-repeat-cursor-old-queue-browsable-no-extra-read")
    }

    func testDiagnoseOriginalFortyFourPercentDrag() {
        let cases: [(Double, Bool)] = [(0.44, false), (0.60, false), (0.44, true), (0.48, true), (0.52, true), (0.60, true)]
        for (fraction, trace) in cases { auditPagingDrag(fraction: fraction, trace: trace, expectedFocus: nil) }
    }

    func testOriginalFortyFourPercentDragReboundsWithoutLosingPage() {
        // This exact short input starts an interactive UIKit transition but
        // does not commit it on the tested runtime. Keep the original distance
        // and API; a longer drag has a separate forward/back paging test.
        for trace in [false, true] {
            auditPagingDrag(fraction: 0.44, trace: trace, expectedFocus: 28_037_102)
        }
    }

    private func auditPagingDrag(fraction: Double, trace: Bool, expectedFocus: Int?) {
        launchContinuation("repeated-cursor", extra: (trace ? ["--qa-pager-touch-trace"] : []) + ["--qa-chrome-geometry"])
        waitPlayingFixture()
        let restart = app.buttons["feed.continuation.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        XCTAssertEqual(watchFocus(), 28_037_102)
        XCTAssertEqual(continuationFields()["requests"], "2")
        let beforePlayer = playerFields()
        let viewport = heightDeck().frame
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (1 + fraction) / 2))
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (1 - fraction) / 2))
        let traceNode = app.staticTexts["pager.qa.trace"]
        let beforeRaw = trace ? traceNode.valueDescription : "{}"
        let beforeTrace = (try? JSONSerialization.jsonObject(with: Data(beforeRaw.utf8))) as? [String: Any]
        let marker = (beforeTrace?["lastSequence"] as? Int) ?? 0
        let startTime = ProcessInfo.processInfo.systemUptime
        lower.press(forDuration: 0.05, thenDragTo: upper)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let focus = watchFocus()
        XCTAssertTrue([28_037_102, 28_037_104].contains(focus), "A drag must settle on an actual member of the retained queue")
        if let expectedFocus { XCTAssertEqual(focus, expectedFocus) }
        heightAssert("recommendation", phase: "drag-\(fraction)-trace\(trace)", expected: focus)
        XCTAssertEqual(continuationFields()["requests"], "2")
        XCTAssertTrue(restart.isHittable)
        if focus == 28_037_102 { assertUnchangedPlayer(beforePlayer, playerFields()) }
        XCTAssertNotNil(videoGeometryReadback(), "A settled drag must retain an actual ready video surface, not a blank page")
        let raw = trace ? traceNode.valueDescription : "{}"
        if trace, expectedFocus == 28_037_102 {
            assertOriginalShortDragTrace(raw, after: marker, viewport: viewport)
        }
        let object: [String: Any] = ["fraction": fraction, "traceEnabled": trace, "eventMarker": marker,
            "pressDuration": 0.05, "gestureAPIVelocity": "default/unspecified",
            "viewport": ["x": viewport.minX, "y": viewport.minY, "width": viewport.width, "height": viewport.height],
            "plannedStart": ["x": viewport.midX, "y": viewport.minY + viewport.height * (1 + fraction) / 2],
            "plannedEnd": ["x": viewport.midX, "y": viewport.minY + viewport.height * (1 - fraction) / 2],
            "wallElapsed": ProcessInfo.processInfo.systemUptime - startTime,
            "finalFocus": focus, "trace": (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [:]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print("PAGER41_DRAG json=\(String(data: data, encoding: .utf8)!)")
        attachScreenshot(named: "pager41-drag-\(fraction)-trace\(trace)-final\(focus)")
        app.terminate()
    }

    private func assertOriginalShortDragTrace(_ raw: String, after marker: Int, viewport: CGRect) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let all = object["events"] as? [[String: Any]], let current = object["current"] as? [String: Any] else {
            XCTFail("The original short drag requires its real native touch/transition trace"); return
        }
        XCTAssertEqual(object["droppedEvents"] as? Int, 0)
        let events = all.filter { ($0["sequence"] as? Int ?? 0) > marker }
        let begins = events.filter { $0["event"] as? String == "touch.began" }
        let ends = events.filter { $0["event"] as? String == "touch.ended" }
        XCTAssertEqual(begins.count, 1); XCTAssertEqual(ends.count, 1)
        guard let begin = begins.first, let end = ends.first,
              let startPoint = begin["windowLocation"] as? [String: Double],
              let endPoint = end["windowLocation"] as? [String: Double],
              let hit = begin["touchView"] as? [String: Any] else { return }
        XCTAssertEqual(begin["touchID"] as? Int, end["touchID"] as? Int)
        XCTAssertEqual(startPoint["x"] ?? -1, Double(viewport.midX), accuracy: 2)
        XCTAssertEqual(startPoint["y"] ?? -1, Double(viewport.minY + viewport.height * 0.72), accuracy: 2)
        XCTAssertEqual(endPoint["x"] ?? -1, Double(viewport.midX), accuracy: 2)
        XCTAssertEqual(endPoint["y"] ?? -1, Double(viewport.minY + viewport.height * 0.28), accuracy: 2)
        XCTAssertEqual(hit["nativeScrollAncestor"] as? Bool, true)
        XCTAssertEqual(hit["controlAncestor"] as? Bool, false)
        XCTAssertTrue(events.contains { $0["event"] as? String == "native.pan" && $0["state"] as? Int == 1 })
        XCTAssertTrue(events.contains { $0["event"] as? String == "native.willTransition" })
        let completion = events.filter { $0["event"] as? String == "native.didFinish" }
        XCTAssertEqual(completion.count, 1)
        XCTAssertEqual(completion.first?["completed"] as? Bool, false)
        XCTAssertTrue(events.contains { $0["event"] as? String == "native.didSettle" && $0["redirected"] as? Bool == false })
        XCTAssertFalse(events.contains { $0["event"] as? String == "window.action" })
        XCTAssertEqual(current["focused"] as? Int, 28_037_102)
        XCTAssertEqual(current["displayedIDs"] as? [Int], [28_037_102])
        XCTAssertEqual(current["transitionActive"] as? Bool, false)
        XCTAssertEqual(current["dragging"] as? Bool, false)
        XCTAssertEqual(current["decelerating"] as? Bool, false)
    }

    private func launchContinuation(_ scenario: String, extra: [String] = []) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-auto-continuation=\(scenario)", "-timeline.presentation", "stream"]
        app.launchArguments += extra
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.staticTexts["continuation.qa.state"].waitForExistence(timeout: 10))
        waitUntil("The fixture must receive the real video filter") { self.continuationFields()["kind"] == "video" }
        printContinuationCounts("launch-ready")
    }
    private func waitForAppearanceContinuation() {
        waitPlayingFixture()
        XCTAssertEqual(watchFocus(), 28_037_102)
        waitUntil("The visible ordinary queue should automatically request a continuation on appearance") {
            (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 2
        }
        printContinuationCounts("after-appearance-fill-demand")
    }
    private func releaseContinuationResponse() {
        let release = app.buttons["continuation.qa.release"]
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        waitUntil("The fake response must wait while real loading is visible") { self.continuationFields()["gate"] == "waiting" && release.isEnabled }
        printContinuationCounts("before-local-response-release")
        release.tap()
        waitUntil("Only the local response gate must be released") { self.continuationFields()["gate"] == "released" }
        printContinuationCounts("after-local-response-release")
    }
    private func printContinuationCounts(_ phase: String) {
        print("CONTINUATION40 phase=\(phase);\(app.staticTexts["continuation.qa.state"].valueDescription)")
    }
    private func assertContinuationActionAccessible(_ action: XCUIElement) {
        let viewport = heightDeck().frame
        let window = app.windows.firstMatch.frame
        let headerHeight: CGFloat = window.width > window.height ? 92 : 104
        let frame = action.frame
        print("CONTINUATION41_ACTION id=\(action.identifier);frame=\(frame);viewport=\(viewport);headerBottom=\(viewport.minY + headerHeight);exists=\(action.exists);enabled=\(action.isEnabled);hittable=\(action.isHittable)")
        XCTAssertTrue(action.isHittable)
        XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThanOrEqual(frame.height + 0.01, 44)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY + headerHeight)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1)
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        if seek.exists { XCTAssertFalse(frame.intersects(seek.frame)) }
        for id in ["timeline.resume", "timeline.notice.text"] {
            let overlay = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if overlay.exists && overlay.isHittable { XCTAssertFalse(frame.intersects(overlay.frame)) }
        }
    }
    private func continuationFields() -> [String: String] { qaFields(app.staticTexts["continuation.qa.state"].valueDescription) }
    private func assertNoFixtureRead(for interval: TimeInterval) {
        printContinuationCounts("before-no-read-window")
        let count = continuationFields()["requests"]
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.continuationFields()["requests"] != count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: interval), .timedOut)
        printContinuationCounts("after-no-read-window")
    }
    private func chromeState() -> XCUIElement { app.staticTexts.matching(identifier: "media.qa.chrome").firstMatch }
    private func playerFields() -> [String: String] { qaFields(app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription) }
    private func videoGeometryReadback() -> (fields: [String: Any], raw: String)? {
        let probe = app.staticTexts.matching(identifier: "media.qa.video-geometry").firstMatch
        guard probe.exists else { return nil }
        let raw = probe.valueDescription
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let surface = fields["surface"] as? String, !surface.isEmpty,
              let ready = fields["ready"] as? Bool, ready,
              layout41HasPositiveRect(fields["videoRect"]),
              layout41HasPositiveRect(fields["videoWindow"]) else { return nil }
        return (fields, raw)
    }
    private func layout41HasPositiveRect(_ value: Any?) -> Bool {
        guard let rect = value as? [String: Any],
              let width = rect["width"] as? Double,
              let height = rect["height"] as? Double else { return false }
        return width > 0 && height > 0
    }
    private func assertVideoGeometryOrientation(_ fields: [String: Any], landscape: Bool) {
        guard let window = fields["window"] as? [String: Any],
              let width = window["width"] as? Double, let height = window["height"] as? Double else {
            XCTFail("Actual window dimensions are missing from geometry readback"); return
        }
        XCTAssertEqual(width > height, landscape, "Read back the actual orientation at every chrome phase")
    }
    private func layout41LogGeometry(_ scenario: String, phase: String,
                                     readback: String) {
        print("LAYOUT41_GEOMETRY case=\(scenario);phase=\(phase);json=\(readback)")
    }
    private func assertVideoGeometryUnchanged(_ before: [String: Any], _ after: [String: Any], phase: String) {
        guard let beforeSurface = before["surface"] as? String, !beforeSurface.isEmpty,
              let afterSurface = after["surface"] as? String, !afterSurface.isEmpty else {
            XCTFail("Missing actual surface UUID at \(phase): before=\(before), after=\(after)")
            return
        }
        XCTAssertEqual(afterSurface, beforeSurface, "Chrome transition must retain the same actual video surface")
        for key in ["surfaceWindow", "layerBounds", "layerFrame", "videoRect", "videoWindow", "windowSafeArea", "transform", "presentationSize", "sourceScale"] {
            guard let left = before[key], let right = after[key] else {
                XCTFail("Missing geometry field \(key) at \(phase); before=\(before), after=\(after)")
                continue
            }
            assertGeometryNumbersEqual(left, right, field: key, phase: phase)
        }
        guard let beforeScale = layout41VideoScale(before), let afterScale = layout41VideoScale(after) else {
            XCTFail("Cannot calculate actual video scale at \(phase); before=\(before), after=\(after)")
            return
        }
        XCTAssertEqual(afterScale.x, beforeScale.x, accuracy: 0.005, "Actual horizontal video scale changed at \(phase)")
        XCTAssertEqual(afterScale.y, beforeScale.y, accuracy: 0.005, "Actual vertical video scale changed at \(phase)")
    }
    private func assertGeometryNumbersEqual(_ lhs: Any, _ rhs: Any, field: String, phase: String) {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            XCTAssertEqual(Set(left.keys), Set(right.keys), "Geometry keys changed for \(field) at \(phase)")
            for key in Set(left.keys).union(right.keys) {
                guard let l = left[key], let r = right[key] else { continue }
                assertGeometryNumbersEqual(l, r, field: "\(field).\(key)", phase: phase)
            }
        } else if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            XCTAssertEqual(left.doubleValue, right.doubleValue, accuracy: 0.5,
                           "Actual geometry \(field) moved over 0.5pt at \(phase)")
        } else if let left = lhs as? String, let right = rhs as? String {
            XCTAssertEqual(left, right, "Geometry value \(field) changed at \(phase)")
        } else {
            XCTAssertEqual(String(describing: lhs), String(describing: rhs), "Geometry value \(field) changed at \(phase)")
        }
    }
    private func layout41VideoScale(_ fields: [String: Any]) -> (x: Double, y: Double)? {
        guard let scale = fields["sourceScale"] as? [String: Any],
              let x = scale["x"] as? Double, x > 0,
              let y = scale["y"] as? Double, y > 0 else { return nil }
        return (x, y)
    }
    private func assertChromePlayerIdentityUnchanged(_ before: [String: String], _ after: [String: String], phase: String) {
        for key in ["player", "prepare", "created", "muted", "rate", "taps", "rateHolds", "seekStarts"] {
            XCTAssertNotNil(before[key], "Missing actual player field \(key) before \(phase)")
            XCTAssertEqual(after[key], before[key], "Chrome transition changed actual player field \(key) at \(phase)")
        }
        XCTAssertEqual(before["muted"], "true", "Layout geometry case must keep actual video muted")
    }
    private func layout41ScrollToHittable(_ element: XCUIElement, in scrollView: XCUIElement,
                                          towardBottom: Bool) -> Bool {
        guard scrollView.waitForExistence(timeout: 5), element.exists else { return false }
        for _ in 0..<12 {
            if element.isHittable { return true }
            if towardBottom { scrollView.swipeUp() } else { scrollView.swipeDown() }
        }
        return element.isHittable
    }
    private func qaFields(_ text: String) -> [String: String] {
        Dictionary(text.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { _, new in new })
    }
    private func waitPlayingFixture() {
        XCTAssertTrue(app.staticTexts.matching(identifier: "media.qa.player").firstMatch.waitForExistence(timeout: 10))
        waitUntil("A real muted AVPlayer must be advancing before gestures") {
            let fields = self.playerFields()
            return fields["player"] != nil && fields["player"] != "none" && fields["rate"] == "1.0" && (Double(fields["position"] ?? "0") ?? 0) > 0.2
        }
        XCTAssertEqual(playerFields()["muted"], "true")
    }
    private func assertUnchangedPlayer(_ before: [String: String], _ after: [String: String]) {
        for key in ["player", "prepare", "created", "muted", "rate", "taps", "rateHolds", "seekStarts"] {
            XCTAssertNotNil(before[key], "Missing actual player QA field \(key)")
            XCTAssertEqual(after[key], before[key], "Chrome/loading UI must not alter actual player field \(key)")
        }
    }
    private func watchFocus() -> Int {
        let geometry = app.staticTexts.matching(identifier: "collection.qa.geometry").allElementsBoundByIndex.first { (heightValues($0.valueDescription)["focused"] ?? -1) > 0 }
        return geometry.map { Int(heightValues($0.valueDescription)["focused"] ?? -1) } ?? -1
    }
    private func assertChromeNotHittable(_ elements: [XCUIElement], phase: String) {
        let receipt = elements.map { "id=\($0.identifier);label=\($0.label);exists=\($0.exists);hittable=\($0.isHittable);frame=\($0.frame)" }.joined(separator: "\n")
        print("CHROME40_SNAPSHOT phase=\(phase);\n\(receipt)")
        let attachment = XCTAttachment(string: receipt + "\n" + String(app.debugDescription.prefix(18000)))
        attachment.name = "chrome40-\(phase)-actual-AX-snapshot"; attachment.lifetime = .keepAlways; add(attachment)
        // Fixed subtrees may remain locatable in XCTest. Their actual snapshot
        // and hit state are evidence; .exists is not a VoiceOver visibility API.
        for element in elements { XCTAssertFalse(element.isHittable, "Hidden chrome must reject hits: \(element.identifier) \(element.label)") }
    }
    private func captureChromePixels(named name: String) -> UIImage? {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return UIImage(data: screenshot.pngRepresentation)
    }
    private func chromeWhitePixels(_ screenshot: UIImage?, in frame: CGRect) -> Int? {
        guard let image = screenshot?.cgImage, app.frame.width > 0, app.frame.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let xScale = CGFloat(image.width) / app.frame.width, yScale = CGFloat(image.height) / app.frame.height
        let crop = CGRect(x: (frame.minX - app.frame.minX) * xScale, y: (frame.minY - app.frame.minY) * yScale,
                          width: frame.width * xScale, height: frame.height * yScale).integral
        guard let region = image.cropping(to: crop), region.width > 0, region.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: region.width, height: region.height,
                                          bitsPerComponent: 8, bytesPerRow: region.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height)); return true
        }
        guard rendered else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] >= 180 && bytes[$0 + 1] >= 180 && bytes[$0 + 2] >= 180 }.count
    }
    private func assertChromePixelsDisappear(before: UIImage?, hidden: UIImage?, regions: [String: CGRect]) {
        for (name, frame) in regions.sorted(by: { $0.key < $1.key }) {
            guard let visible = chromeWhitePixels(before, in: frame), let absent = chromeWhitePixels(hidden, in: frame) else {
                XCTFail("Could not decode actual screenshot pixels for \(name): \(frame)"); continue
            }
            print("CHROME40_PIXELS region=\(name);frame=\(frame);visibleWhite=\(visible);hiddenWhite=\(absent)")
            XCTAssertGreaterThan(visible, 8, "The controlled static image must first expose visible chrome pixels in \(name)")
            XCTAssertLessThanOrEqual(Double(absent), max(8, Double(visible) * 0.15), "Hidden chrome must remove the original white glyph/background pixels in \(name)")
        }
    }
    private func tapScreenFrame(_ frame: CGRect) {
        XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
    private func centralPress() {
        let frame = heightDeck().frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).press(forDuration: 0.7)
    }
    private func waitUntil(_ message: String, timeout: TimeInterval = 8, _ predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func mainTabButton(_ title: String) -> XCUIElement {
        let ids = ["时间线": "main.tab.timeline", "作者榜": "main.tab.2", "搜索": "main.tab.4", "我": "main.tab.3"]
        if let identifier = ids[title] { return mainTabBar().buttons.matching(identifier: identifier).firstMatch }
        // Negative checks for a removed tab must query it, never manufacture it.
        return mainTabBar().buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func mainTabBar() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "main.tabs.compact").firstMatch
    }

    private func visualButton(_ id: String) -> XCUIElement {
        let candidates = app.buttons.matching(identifier: id).allElementsBoundByIndex
        return candidates.first(where: { $0.isHittable }) ?? app.buttons.matching(identifier: id).firstMatch
    }

    func testWatchingViewportTimelineHeightAndRotation() {
        for route in ["recommendation", "following", "timeline-grid", "timeline-resume"] {
            auditWatchingRoute(route, rotates: route == "recommendation" || route == "timeline-grid")
        }
    }

    func testWatchingViewportOtherEntriesHeightAndRotation() {
        for route in ["author", "author-video", "search", "collections", "offline", "history", "history-resume"] {
            auditWatchingRoute(route, rotates: ["author-video", "offline", "history-resume"].contains(route))
        }
    }

    func testWatchingViewportTimelineResumeHeightAndRotation() {
        auditWatchingRoute("timeline-resume", rotates: true)
    }

    func testWatchingViewportCompactDynamicTypeHeightAndRotation() {
        auditWatchingRoute("recommendation", rotates: true, compact: true)
    }

    func testWatchingViewportShortLandscapeKeepsGesturesAroundResumePrompt() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-height-audit"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("时间线").tap()
        let mode = app.buttons["timeline.presentation"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.valueDescription.contains("双列网格") { mode.tap() }
        app.segmentedControls["timeline.media-kind"].buttons["全部"].tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "timeline.resume", "上次推荐")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 8)); XCTAssertTrue(resume.isHittable)
        heightDeck().swipeUp(); heightDeck().swipeUp()
        heightAssert("recommendation", phase: "prompt-video", expected: 28_037_102)
        app.buttons["手动切换横竖屏"].tap()
        heightWaitOrientation(landscape: true)
        heightAssert("recommendation", phase: "prompt-video-landscape", expected: 28_037_102)
        XCTAssertTrue(resume.isHittable, "The prompt itself must remain interactive")
        let frame = heightDeck().frame
        func exposedPoint() -> XCUICoordinate {
            let viewport = heightDeck().frame, window = app.windows.firstMatch.frame
            let headerBottom = viewport.minY + (window.width > window.height ? 92 : 104)
            let social = app.buttons["media.author.28037102"].frame
            let top = max(headerBottom, resume.isHittable ? resume.frame.maxY : headerBottom) + 6
            let bottom = social.minY - 6
            XCTAssertGreaterThan(bottom, top, "Actual header, prompt and author row must leave exposed media")
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: (top + bottom) / 2))
        }
        let exposed = exposedPoint()
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10)); XCTAssertTrue(seek.isHittable)
        XCTAssertTrue(app.buttons["取消静音"].isHittable, "The player must stay muted throughout QA")
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        exposed.tap()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let paused = seekSeconds(seek.valueDescription)!
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(seekSeconds(seek.valueDescription)!, paused, accuracy: 0.5, "A tap beside the prompt must pause playback")
        exposed.tap()
        let playing = NSPredicate { _, _ in (self.seekSeconds(seek.valueDescription) ?? paused) >= paused + 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 4), .completed)
        let rotationControl = app.buttons["手动切换横竖屏"]
        let controlFrame = rotationControl.frame
        guard let rawSeeksBefore = playerFields()["seekStarts"], let seeksBeforeControlDrag = Int(rawSeeksBefore) else {
            XCTFail("Missing numeric seekStarts before control-origin drag"); return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: controlFrame.midX, dy: controlFrame.midY))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: controlFrame.midX - 168, dy: controlFrame.midY)))
        XCTAssertTrue(app.segmentedControls["timeline.media-kind"].buttons["全部"].isSelected,
                      "A drag starting inside the rotate control must not switch the media filter")
        guard let rawSeeksAfter = playerFields()["seekStarts"], let seeksAfterControlDrag = Int(rawSeeksAfter) else {
            XCTFail("Missing numeric seekStarts after control-origin drag"); return
        }
        print("TIGHT_FOOTER42_CONTROL_ORIGIN seekStartsBefore=\(seeksBeforeControlDrag);seekStartsAfter=\(seeksAfterControlDrag)")
        XCTAssertEqual(seeksAfterControlDrag, seeksBeforeControlDrag,
                       "A drag starting inside a control must not seek the video")
        let edgeY = seek.frame.minY - 4
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 12, dy: edgeY))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 180, dy: edgeY)))
        let video = app.segmentedControls["timeline.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForValueToContain("1", timeout: 3) || video.isSelected)
        heightAssert("recommendation", phase: "prompt-edge-switch-result", expected: 28_037_102)
        // Replacing a filtered queue may recreate its orientation scope. Use
        // the resulting viewport for the next gesture rather than stale points.
        exposedPoint().doubleTap()
        XCTAssertTrue(app.navigationBars["作者作品"].waitForExistence(timeout: 8))
        print("HEIGHT_GESTURES prompt-visible landscape-video single-tap-pause-resume edge-switch double-tap-author passed")
        attachScreenshot(named: "height-landscape-prompt-author")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }

    private func auditWatchingRoute(_ route: String, rotates: Bool, compact: Bool = false) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-height-audit"]
        if compact { app.launchArguments += ["--qa-theme-compact"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let videoStart = route == "author-video" || route == "history-resume" || route == "timeline-resume"
        let start = 28_037_100 + (videoStart ? 2 : 0)
        heightOpen(route, expected: start)
        heightAssert(route, phase: "entry", expected: start)
        heightCloseNotices()
        let next = route == "author-video" ? 28_037_104 : start + 1
        heightDeck().swipeUp()
        heightAssert(route, phase: "next", expected: next)
        heightDeck().swipeDown()
        heightAssert(route, phase: "previous", expected: start)
        if !videoStart && route != "author" {
            heightDeck().swipeUp(); heightAssert(route, phase: "shorter-image", expected: start + 1)
            heightDeck().swipeUp(); heightAssert(route, phase: "video", expected: start + 2)
            heightDeck().swipeDown(); heightDeck().swipeDown()
            heightAssert(route, phase: "return-first", expected: start)
        }
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(details); details?.tap()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        heightAssert(route, phase: "details-return", expected: start)
        if rotates {
            app.buttons["手动切换横竖屏"].tap()
            heightWaitOrientation(landscape: true)
            heightAssert(route, phase: "landscape", expected: start)
            app.buttons["手动切换横竖屏"].tap()
            heightWaitOrientation(landscape: false)
            heightAssert(route, phase: "portrait-return", expected: start)
        }
        heightCloseNotices()
        // Tap the exposed media, above the actual footer, rather than a global
        // screen coordinate that may belong to a toolbar or a playback control.
        let deckFrame = heightDeck().frame
        let info = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable })!
        let inline = ["recommendation", "following", "timeline-resume"].contains(route)
        let firstY = deckFrame.minY + (inline ? 5 : 115)
        let lastY = info.frame.minY - 8
        XCTAssertGreaterThan(lastY, firstY, "A usable media gesture area must remain between chrome and footer")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deckFrame.midX, dy: (firstY + lastY) / 2)).doubleTap()
        XCTAssertTrue(app.navigationBars["作者作品"].waitForExistence(timeout: 8))
        if route == "author" || route == "author-video" {
            XCTAssertTrue(app.buttons["media.grid.cell.\(start)"].waitForExistence(timeout: 5))
            heightTap(app.buttons["media.grid.cell.\(start)"])
        } else {
            let back = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.first(where: { $0.isHittable })
            XCTAssertNotNil(back); back?.tap()
        }
        heightAssert(route, phase: "author-return", expected: start)
        if !inline {
            let close = app.buttons[route.hasPrefix("history") ? "关闭浏览记录" : "关闭作品"]
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
            heightOpen(route, expected: start)
            heightAssert(route, phase: "reentry", expected: start)
        }
        app.terminate()
    }

    private func heightOpen(_ route: String, expected: Int) {
        if ["recommendation", "following", "timeline-grid", "timeline-resume"].contains(route) {
            mainTabButton("时间线").tap()
            let mode = app.buttons["timeline.presentation"]
            XCTAssertTrue(mode.waitForExistence(timeout: 10))
            let wantsGrid = route == "timeline-grid"
            if mode.valueDescription.contains(wantsGrid ? "信息流" : "双列网格") { mode.tap() }
            app.buttons[route == "following" ? "timeline.source.following" : "timeline.source.recommendation"].tap()
            if route == "timeline-resume" {
                let resume = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "timeline.resume", "上次推荐")).firstMatch
                XCTAssertTrue(resume.waitForExistence(timeout: 8))
                attachScreenshot(named: "height-timeline-resume-before-tap")
                XCTAssertTrue(resume.isHittable)
                resume.tap()
            } else {
                heightCloseNotices()
                let all = app.segmentedControls["timeline.media-kind"].buttons["全部"]
                XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
            }
            if wantsGrid { heightTap(app.buttons["media.grid.cell.\(expected)"]) }
            return
        }
        if route.hasPrefix("author") {
            let cell = app.buttons["media.grid.cell.\(expected)"]
            if !cell.isHittable {
                mainTabButton("作者榜").tap()
                let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pattern Creator 1")).firstMatch
                heightTap(creator)
                let kind = app.segmentedControls["creator.media-kind"].buttons[route == "author-video" ? "视频" : "图片"]
                XCTAssertTrue(kind.waitForExistence(timeout: 5)); kind.tap()
            }
            heightTap(cell); return
        }
        if route == "search" {
            let cell = app.buttons["media.grid.cell.\(expected)"]
            if !cell.isHittable {
                mainTabButton("搜索").tap()
                let field = app.textFields["search-title-input"]
                XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Paging\n")
            }
            heightTap(cell); return
        }
        mainTabButton("我").tap()
        if route == "collections" {
            let cell = app.buttons["media.grid.cell.\(expected)"]
            if !cell.isHittable {
                heightTap(app.buttons["我的收藏"])
                heightTap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch)
            }
            heightTap(cell)
        } else if route == "offline" {
            let row = app.buttons["offline.item.\(expected)"]
            if !row.isHittable { heightTap(app.buttons["离线收藏与空间管理"]) }
            heightTap(row)
        } else {
            if !app.navigationBars["最近浏览"].exists { heightTap(app.buttons["最近浏览与接着看"]) }
            if route == "history-resume" {
                heightTap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "推荐时间线")).firstMatch)
            } else { heightTap(app.buttons["history.item.\(expected)"]) }
        }
    }

    private func heightTap(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { element.tap(); return }
            let down = element.exists && element.frame.maxY < app.windows.firstMatch.frame.midY
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.65))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.35)))
        }
        XCTFail("Height audit entry is not reachable: \(element.identifier)")
    }

    private func heightDeck() -> XCUIElement {
        let candidates = ["media.viewer.deck", "timeline.media.deck"].flatMap { app.scrollViews.matching(identifier: $0).allElementsBoundByIndex }
        return candidates.first(where: { $0.isHittable }) ?? app.scrollViews["media.viewer.deck"]
    }

    private func heightCloseNotices() {
        for id in ["timeline.resume.close", "timeline.notice.close"] {
            let button = app.buttons[id]
            if button.exists && button.isHittable { button.tap() }
        }
    }

    private func heightWaitOrientation(landscape: Bool) {
        let stable = NSPredicate { _, _ in
            let f = self.heightDeck().frame, window = self.app.windows.firstMatch.frame
            return f.width > 0 && f.height > 0 && (window.width > window.height) == landscape
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 8), .completed)
        // The manual app request changes its geometry before the simulator's
        // device orientation. Match the device so screenshots use one orientation.
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    private func heightAssert(_ route: String, phase: String, expected: Int) {
        let geometries = app.staticTexts.matching(identifier: "collection.qa.geometry")
        let stable = NSPredicate { _, _ in
            geometries.allElementsBoundByIndex.contains { element in
                let v = self.heightValues(element.valueDescription)
                guard Int(v["focused"] ?? 0) == expected,
                      let py = v["pageY"], let vy = v["viewportY"], let ph = v["pageH"], let vh = v["viewportH"],
                      let px = v["pageX"], let vx = v["viewportX"], let pw = v["pageW"], let vw = v["viewportW"] else { return false }
                return vh > 0 && vw > 0 && abs(py-vy) < 1 && abs(ph-vh) < 1 && abs(px-vx) < 1 && abs(pw-vw) < 1 && v["neighborOverlap"] == 0
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 10), .completed,
                       "\(route)/\(phase) must expose one settled whole page")
        let geometry = geometries.allElementsBoundByIndex.first { Int(heightValues($0.valueDescription)["focused"] ?? 0) == expected }!
        let v = heightValues(geometry.valueDescription)
        if ["recommendation", "following", "timeline-resume"].contains(route) {
            let picker = app.segmentedControls["timeline.media-kind"].frame
            let tabs = mainTabBar().frame
            XCTAssertLessThanOrEqual(v["viewportY"] ?? 0, picker.minY + 1,
                                     "The stable canvas must extend behind the overlaid header")
            XCTAssertGreaterThanOrEqual((v["viewportY"] ?? 0)+(v["viewportH"] ?? 0), tabs.maxY - 1,
                                        "The stable canvas must extend behind the overlaid bottom tabs")
        }
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).allElementsBoundByIndex.first(where: { $0.isHittable })
        if let seek {
            XCTAssertEqual(seek.frame.height, 44, accuracy: 1)
            XCTAssertGreaterThanOrEqual(seek.frame.minY, v["viewportY"] ?? 0)
            XCTAssertLessThanOrEqual(seek.frame.maxY, (v["viewportY"] ?? 0)+(v["viewportH"] ?? 0)+1)
            if ["recommendation", "following", "timeline-resume"].contains(route) {
                XCTAssertLessThanOrEqual(seek.frame.maxY, mainTabBar().frame.minY + 1,
                                         "The seek target must remain above the overlaid tabs")
            }
        }
        print("HEIGHT_AUDIT route=\(route);phase=\(phase);\(geometry.valueDescription)")
        attachScreenshot(named: "height-\(route)-\(phase)")
    }

    private func heightValues(_ text: String) -> [String: Double] {
        Dictionary(text.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "="); guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }, uniquingKeysWith: { _, new in new })
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitUI37Evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name)-\(UUID().uuidString).png"), options: .atomic)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activeMediaDeck() -> XCUIElement {
        let matches = app.scrollViews.matching(identifier: "timeline.media.deck").allElementsBoundByIndex
        return matches.first(where: { $0.isHittable }) ?? app.scrollViews.matching(identifier: "timeline.media.deck").firstMatch
    }

    private func metric(_ name: String, in value: String) -> Int {
        guard let range = value.range(of: #"\b\#(name)=(\d+)"#, options: .regularExpression),
              let digits = value[range].range(of: #"\d+"#, options: .regularExpression) else { return -1 }
        return Int(value[digits]) ?? -1
    }

    private func seekSeconds(_ value: String) -> Double? {
        guard let position = value.components(separatedBy: " / ").first else { return nil }
        let parts = position.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForValueToContain(_ value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in self.valueDescription.contains(value) }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    var valueDescription: String { (value as? String) ?? label }
}
