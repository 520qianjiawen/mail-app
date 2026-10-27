import AppKit
import SwiftUI
import WebKit

/// Integration checks for the real delegate, Binding updates, width callback,
/// navigation revision guards and teardown. Only temporary fixture state is used.
@MainActor func runMailBodyCoordinatorChecks(_ require: (Bool, String) throws -> Void) async throws {
    let state = AppState(fixture: true)
    state.start()
    guard let message = state.rows.first else {
        throw NSError(domain: "MailBodyCoordinatorTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Fixture has no message"])
    }
    var height: CGFloat = 2500
    let parent = MailBodyView(html: "", inline: [], message: message, state: state,
                              detailHTML: "", allowRemote: false, dark: false, paper: false,
                              sessionImageSources: [],
                              height: Binding(get: { height }, set: { height = $0 }),
                              webView: .constant(nil))
    let coordinator = parent.makeCoordinator()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.setURLSchemeHandler(coordinator, forURLScheme: "mail-inline")
    let view = EmailBodyWKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 2500), configuration: configuration)
    view.navigationDelegate = coordinator
    view.onContentWidthChanged = { [weak coordinator] view in coordinator?.measure(view) }
    defer {
        MailBodyView.dismantleNSView(view, coordinator: coordinator)
    }

    func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    let short = MailHTML.document("<p>Short integration fixture.</p>")
    coordinator.load(short, into: view)
    let initialShrank = try await waitUntil { height >= 40 && height < 200 }
    try require(initialShrank, "production delegate updates a 2500px height Binding to the short body's natural height (\(height)px)")

    let long = MailHTML.document(String(repeating: "<p>A long previous message paragraph.</p>", count: 100))
    height = 2500
    coordinator.load(long, into: view)
    coordinator.load(short, into: view)
    let replacementShrank = try await waitUntil { height >= 40 && height < 200 }
    try await Task.sleep(nanoseconds: 450_000_000)
    try require(replacementShrank && height < 200,
                "rapid long/short navigation and delayed old callbacks cannot restore a stale tall Binding")

    let wrapping = MailHTML.document("<p>" + String(repeating: "Customer pricing and delivery details. ", count: 30) + "</p>")
    height = 2500
    coordinator.load(wrapping, into: view)
    let wideReady = try await waitUntil { height >= 100 && height < 500 }
    try require(wideReady, "production delegate measures the wide paragraph (\(height)px)")
    let wideHeight = height
    view.setFrameSize(NSSize(width: 260, height: 2500))
    view.layoutSubtreeIfNeeded()
    let narrowReady = try await waitUntil { height > wideHeight * 1.5 && height < 1500 }
    try require(narrowReady, "production width-change callback automatically remeasures narrower text (\(height)px)")
    view.setFrameSize(NSSize(width: 900, height: 2500))
    view.layoutSubtreeIfNeeded()
    let wideAgain = try await waitUntil { abs(height - wideHeight) <= 2 }
    try require(wideAgain, "production width-change callback shrinks the height after widening")

    coordinator.measure(view)
    coordinator.invalidate()
    height = 555
    try await Task.sleep(nanoseconds: 250_000_000)
    try require(height == 555, "teardown cancels queued measurements so a retired reader cannot write to its Binding")
}
