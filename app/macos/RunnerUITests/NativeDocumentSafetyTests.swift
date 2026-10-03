import XCTest

final class NativeDocumentSafetyTests: XCTestCase {
  private var app: XCUIApplication!
  private var documentsDirectory: URL!
  private var projectDirectory: URL!
  private var recoveryProject: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    let runID = "native-close-\(name)-\(UUID().uuidString.lowercased())"
    let appDocuments = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/org.projectink.studio/Data/Documents")
    documentsDirectory = appDocuments
      .appendingPathComponent("ProjectInkAlphaValidation", isDirectory: true)
      .appendingPathComponent(runID, isDirectory: true)
      .appendingPathComponent("documents", isDirectory: true)
    projectDirectory = documentsDirectory.appendingPathComponent("projects", isDirectory: true)
    recoveryProject = documentsDirectory
      .appendingPathComponent("Project Ink/Recovery/last-session.inkproj", isDirectory: true)

    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    app = XCUIApplication()
    app.launchEnvironment["PROJECT_INK_TEST_DOCUMENTS_PATH"] = documentsDirectory.path
  }

  override func tearDownWithError() throws {
    if app.state != .notRunning {
      app.terminate()
    }
    super.tearDown()
  }

  func testRedCloseCancelKeepsDirtyNamedProjectOpen() throws {
    let project = try startDirtyNamedProject()
    requestWindowClose()
    chooseUnsavedAction("Cancel")

    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(drawingCanvas.waitForExistence(timeout: 5))
    let unchangedProject = try projectSnapshot(project.url)
    XCTAssertEqual(unchangedProject, project.baseline)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryProject.path))
    attachScreenshot("red-close-cancel-keeps-document")
  }

  func testRedCloseDiscardPreservesNamedProjectAndRemovesRecovery() throws {
    let project = try startDirtyNamedProject()
    requestWindowClose()
    chooseUnsavedAction("Discard")

    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
    let unchangedProject = try projectSnapshot(project.url)
    XCTAssertEqual(unchangedProject, project.baseline)
    XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryProject.path))

    launchCanvas()
    XCTAssertFalse(app.staticTexts["Unsaved changes"].exists)
    attachScreenshot("red-close-discard-clean-relaunch")
  }

  func testRedCloseSavePersistsNamedProjectBeforeWindowCloses() throws {
    let project = try startDirtyNamedProject()
    requestWindowClose()
    chooseUnsavedAction("Save")

    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
    let savedProject = try projectSnapshot(project.url)
    XCTAssertNotEqual(savedProject, project.baseline)
    XCTAssertTrue(
      containsChangedTile(in: savedProject, comparedWith: project.baseline),
      "Save changed package metadata but did not persist a canvas tile"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryProject.path))
  }

  func testCommandQCancelKeepsDirtyNamedProjectOpen() throws {
    let project = try startDirtyNamedProject()
    app.typeKey("q", modifierFlags: [.command])
    chooseUnsavedAction("Cancel")

    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(drawingCanvas.waitForExistence(timeout: 5))
    let unchangedProject = try projectSnapshot(project.url)
    XCTAssertEqual(unchangedProject, project.baseline)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryProject.path))
    attachScreenshot("command-q-cancel-keeps-document")
  }

  func testCommandQDiscardPreservesNamedProjectAndRemovesRecovery() throws {
    let project = try startDirtyNamedProject()
    app.typeKey("q", modifierFlags: [.command])
    chooseUnsavedAction("Discard")

    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
    let unchangedProject = try projectSnapshot(project.url)
    XCTAssertEqual(unchangedProject, project.baseline)
    XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryProject.path))

    launchCanvas()
    XCTAssertFalse(app.staticTexts["Unsaved changes"].exists)
    attachScreenshot("command-q-discard-clean-relaunch")
  }

  func testCommandQSavePersistsNamedProjectBeforeAppQuits() throws {
    let project = try startDirtyNamedProject()
    app.typeKey("q", modifierFlags: [.command])
    chooseUnsavedAction("Save")

    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
    let savedProject = try projectSnapshot(project.url)
    XCTAssertNotEqual(savedProject, project.baseline)
    XCTAssertTrue(
      containsChangedTile(in: savedProject, comparedWith: project.baseline),
      "Save changed package metadata but did not persist a canvas tile"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryProject.path))
  }

  private var drawingCanvas: XCUIElement {
    let canvasSemantics = NSPredicate(
      format: "identifier == %@ OR label == %@",
      "drawing-canvas",
      "Drawing canvas"
    )
    return app.descendants(matching: .any).matching(canvasSemantics).firstMatch
  }

  private func launchCanvas() {
    app.launch()
    app.activate()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 10),
      "Project Ink launched but macOS did not bring it to the foreground. "
        + "Check Xcode UI automation and accessibility permissions."
    )
    let mainWindow = app.windows.firstMatch
    XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Project Ink has no main window.")
    XCTAssertTrue(
      mainWindow.isHittable,
      "Project Ink is foregrounded but its main window is not hittable by UI automation. "
        + "Window accessibility state: \(mainWindow.debugDescription)"
    )
    XCTAssertTrue(
      drawingCanvas.waitForExistence(timeout: 30),
      "Project Ink is foregrounded but the Flutter drawing canvas is missing. "
        + "Accessibility hierarchy: \(app.debugDescription)"
    )
  }

  private func startDirtyNamedProject() throws -> NamedProject {
    launchCanvas()

    let projectName = "\(name.lowercased())-\(UUID().uuidString.prefix(8))"
    app.typeKey("s", modifierFlags: [.command, .shift])
    let nameDialog = app.staticTexts["Save project"]
    XCTAssertTrue(nameDialog.waitForExistence(timeout: 10))
    let nameField = app.textFields.firstMatch
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))
    nameField.click()
    nameField.typeKey("a", modifierFlags: [.command])
    nameField.typeText(projectName)
    app.buttons["Save"].tap()
    chooseNativeDirectory(projectDirectory, confirmButton: "Choose save location")

    let projectURL = projectDirectory.appendingPathComponent("\(projectName).inkproj", isDirectory: true)
    XCTAssertTrue(waitForPath(projectURL, timeout: 20), "Save did not publish \(projectURL.path)")
    let baseline = try projectSnapshot(projectURL)

    let canvas = drawingCanvas
    let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.31))
    let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.69))
    start.press(forDuration: 0.1, thenDragTo: end)

    XCTAssertTrue(waitForPath(recoveryProject, timeout: 12), "Drawing did not create its recovery checkpoint")
    return NamedProject(url: projectURL, baseline: baseline)
  }

  private func requestWindowClose() {
    let closeButton = app.windows.firstMatch.buttons["Close"]
    XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "The AppKit close button is unavailable")
    closeButton.click()
  }

  private func chooseUnsavedAction(_ title: String) {
    XCTAssertTrue(app.staticTexts["Unsaved changes"].waitForExistence(timeout: 10))
    let choice = app.buttons[title]
    XCTAssertTrue(choice.waitForExistence(timeout: 5), "Missing Unsaved changes action: \(title)")
    choice.click()
  }

  private func chooseNativeDirectory(_ directory: URL, confirmButton: String) {
    let panel = app.dialogs.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 15), "The native directory picker did not open")
    app.typeKey("g", modifierFlags: [.command, .shift])

    let goToFolder = app.sheets.firstMatch
    XCTAssertTrue(goToFolder.waitForExistence(timeout: 5), "Go to Folder did not open")
    let pathField = goToFolder.textFields.firstMatch
    XCTAssertTrue(pathField.waitForExistence(timeout: 3))
    pathField.click()
    pathField.typeText(directory.path)
    pathField.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

    let confirm = app.buttons[confirmButton]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Picker action \(confirmButton) is unavailable")
    confirm.click()
  }

  private func waitForPath(_ url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: url.path) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return FileManager.default.fileExists(atPath: url.path)
  }

  private func projectSnapshot(_ url: URL) throws -> [String: Data] {
    var enumerationError: Error?
    guard let files = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else {
      throw CocoaError(.fileReadUnknown)
    }

    var snapshot: [String: Data] = [:]
    for case let fileURL as URL in files {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      let data = try Data(contentsOf: fileURL)
      snapshot[String(fileURL.path.dropFirst(url.path.count + 1))] = data
    }
    if let enumerationError { throw enumerationError }
    return snapshot
  }

  private func containsChangedTile(
    in current: [String: Data],
    comparedWith baseline: [String: Data]
  ) -> Bool {
    current.contains { entry in
      entry.key.hasPrefix("tiles/") && baseline[entry.key] != entry.value
    }
  }

  private func attachScreenshot(_ title: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = title
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private struct NamedProject {
    let url: URL
    let baseline: [String: Data]
  }
}
