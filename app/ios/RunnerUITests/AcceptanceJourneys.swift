import XCTest

final class AcceptanceJourneys: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["--acceptance-ui-test"]
  }

  func testCanvasIsAvailableAfterFreshProcessRelaunch() throws {
    app.launch()
    XCTAssertTrue(openProjectButton.waitForExistence(timeout: 30))
    app.terminate()

    app = XCUIApplication()
    app.launchArguments += ["--acceptance-ui-test"]
    app.launch()
    XCTAssertTrue(openProjectButton.waitForExistence(timeout: 30))
    XCTAssertTrue(app.state == .runningForeground)
    attachScreenshot("canvas-after-process-relaunch")
  }

  func testNativeProjectPickerCanOpenAndDismiss() throws {
    app.launch()
    XCTAssertTrue(openProjectButton.waitForExistence(timeout: 30))
    openProjectButton.tap()

    attachScreenshot("native-files-picker-open")
    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 15))
    cancel.tap()
    XCTAssertTrue(openProjectButton.waitForExistence(timeout: 10))
  }

  private var openProjectButton: XCUIElement {
    app.buttons["open-project"]
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
