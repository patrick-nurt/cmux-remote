import XCTest

/// Deep links are how a tapped ntfy push navigates into a workspace/surface
/// (`cmux://surface/<uuid>?workspace=<uuid>`). The OS asks for confirmation
/// before handing a custom-scheme URL to the app, which UI tests cannot
/// answer, so the app accepts the same URL via CMUX_DEEPLINK_URL at launch
/// (same convention as CMUX_FAKE_RELAY).
@MainActor
final class DeepLinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(deepLink: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        if let deepLink {
            app.launchEnvironment["CMUX_DEEPLINK_URL"] = deepLink
        }
        app.launch()
        return app
    }

    /// Without a deep link the app stays on the workspace list.
    func testWithoutDeepLinkStaysOnWorkspaceList() throws {
        let app = launch(deepLink: nil)
        waitFor(app.buttons["agent-lab"], predicate: "exists == true AND hittable == true", in: app)
        XCTAssertFalse(
            app.otherElements["TerminalAccessoryPanel"].exists,
            "workspace list should not show the terminal surface"
        )
    }

    /// A `cmux://suite/<surface>?workspace=<ws>` link must land directly on
    /// that workspace's terminal — no taps.
    func testDeepLinkOpensWorkspaceSurface() throws {
        let app = launch(deepLink: "cmux://surface/SF-DEMO-1B?workspace=WS-DEMO-1")
        waitFor(app.otherElements["TerminalAccessoryPanel"], predicate: "exists == true", in: app)

        // The requested surface is the codex tab of the agent-lab workspace.
        let codex = app.buttons["codex"]
        waitFor(codex, predicate: "exists == true", in: app)
    }

    /// An unknown workspace must fall back to the inbox rather than a blank
    /// screen (the Mac may have closed the workspace since the push was sent).
    func testDeepLinkToUnknownWorkspaceFallsBackToInbox() throws {
        let app = launch(deepLink: "cmux://surface/SF-GONE?workspace=WS-GONE")
        waitFor(app.staticTexts["INBOX"], predicate: "exists == true", in: app)
        XCTAssertFalse(
            app.otherElements["TerminalAccessoryPanel"].exists,
            "unknown target should not open a terminal"
        )
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate: String,
        timeout: TimeInterval = 20,
        in app: XCUIApplication
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, app.debugDescription)
    }
}
