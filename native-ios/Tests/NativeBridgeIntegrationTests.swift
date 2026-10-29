import XCTest
import UIKit
import WebKit
import SwiftUI
@testable import KcalAnalysis

/// Runs the bundled application in Apple's real WebKit, with only native health
/// results and URL opening replaced. Every snapshot lives in a temporary test directory.
final class NativeBridgeIntegrationTests: XCTestCase {
    typealias Completion = (Result<[String: Any], Error>) -> Void

    private final class FakeHealth: NativeHealthProviding {
        let isAvailable = true
        var authorizationCount = 0
        var syncRequests: [[String: Any]] = []
        var holdAuthorization = false
        var pendingAuthorization: Completion?
        var onAuthorize: (() -> Void)?
        var onSync: (() -> Void)?
        var syncResult: Result<[String: Any], Error> = .success([
            "daily": NSNull(), "sleepSamples": NSNull(), "sleepSources": [],
            "notes": ["Synthetic empty HealthKit response"]
        ])

        func authorize(completion: @escaping Completion) {
            authorizationCount += 1
            onAuthorize?()
            if holdAuthorization { pendingAuthorization = completion }
            else { completion(.success(["requestCompleted": true])) }
        }

        func finishAuthorization(_ result: Result<[String: Any], Error>) {
            let completion = pendingAuthorization
            pendingAuthorization = nil
            completion?(result)
        }

        func sync(params: [String: Any], completion: @escaping Completion) {
            syncRequests.append(params)
            onSync?()
            completion(syncResult)
        }
    }

    private final class LauncherRecorder {
        var urls: [URL] = []
        var results: [Bool] = []

        func makeLauncher() -> ExternalAppLauncher {
            ExternalAppLauncher { url, _, completion in
                self.urls.append(url)
                completion(self.results.isEmpty ? false : self.results.removeFirst())
            }
        }
    }

    @MainActor
    func testEmptyFirstLaunchUsesRealOriginAndEntersHealthAuthorization() async throws {
        let authorized = expectation(description: "A real WKWebView click reaches health.authorize")
        let queried = expectation(description: "Authorization completion reaches health.sync")
        let health = FakeHealth()
        health.holdAuthorization = true
        health.onAuthorize = { authorized.fulfill() }
        health.onSync = { queried.fulfill() }

        try await withApplication(health: health) { controller, store, recorder in
            let webView = try XCTUnwrap(controller.webView)
            let pong = try await self.bridgeCall("bridge.ping", in: webView)
            XCTAssertEqual(pong["protocolVersion"] as? Int, 2)
            XCTAssertEqual(pong["healthAvailable"] as? Bool, true)
            XCTAssertEqual(pong["nativeNavigation"] as? Bool, true)
            XCTAssertNotNil(pong["appVersion"] as? String)
            XCTAssertNotNil(pong["buildNumber"] as? String)
            XCTAssertEqual(controller.bridge.lastMessageOrigin?.scheme, "kcalapp")
            XCTAssertEqual(controller.bridge.lastMessageOrigin?.host, "localhost")
            XCTAssertNil(try store.load(), "Opening and connecting the bridge must not create a snapshot")
            try await self.assertJavaScript("storageReadError", equals: false, in: webView)

            try await self.openHealthAndClickSync(in: webView)
            await self.fulfillment(of: [authorized], timeout: 5)
            XCTAssertEqual(health.authorizationCount, 1)
            XCTAssertTrue(health.syncRequests.isEmpty, "No read occurs before authorization completes")
            try await self.assertJavaScript("document.getElementById('btnNativeSync').disabled", equals: true, in: webView)
            let authorizingStatus = try await self.status(in: webView)
            XCTAssertTrue(authorizingStatus.contains("授权"), "The pending authorization must have immediate visible feedback")

            health.finishAuthorization(.success(["requestCompleted": true]))
            await self.fulfillment(of: [queried], timeout: 5)
            try await self.waitForJavaScript("!document.getElementById('btnNativeSync').disabled && document.getElementById('nativeSyncStatus').textContent.includes('没有可更新')", in: webView)
            XCTAssertEqual(health.syncRequests.count, 1)
            XCTAssertNotNil(health.syncRequests.first?["from"] as? String)
            XCTAssertNotNil(health.syncRequests.first?["through"] as? String)
            XCTAssertNil(try store.load(), "Empty reads must not create or overwrite records")
            XCTAssertTrue(recorder.urls.isEmpty)
        }
    }

    @MainActor
    func testAuthorizationFailureShowsItsReasonAndDoesNotWrite() async throws {
        let authorized = expectation(description: "Authorization is requested")
        let health = FakeHealth()
        health.holdAuthorization = true
        health.onAuthorize = { authorized.fulfill() }

        try await withApplication(health: health) { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            try await self.openHealthAndClickSync(in: webView)
            await self.fulfillment(of: [authorized], timeout: 5)
            health.finishAuthorization(.failure(NativeFailure("synthetic_authorization", "Synthetic authorization failure")))
            try await self.waitForJavaScript("!document.getElementById('btnNativeSync').disabled && document.getElementById('nativeSyncStatus').textContent.includes('Synthetic authorization failure')", in: webView)
            XCTAssertEqual(health.authorizationCount, 1)
            XCTAssertTrue(health.syncRequests.isEmpty)
            XCTAssertNil(try store.load())
        }
    }

    @MainActor
    func testQueryFailureShowsItsReasonAndDoesNotWrite() async throws {
        let health = FakeHealth()
        health.syncResult = .failure(NativeFailure("synthetic_query", "Synthetic query failure"))
        try await withApplication(health: health) { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            try await self.openHealthAndClickSync(in: webView)
            try await self.waitForJavaScript("!document.getElementById('btnNativeSync').disabled && document.getElementById('nativeSyncStatus').textContent.includes('Synthetic query failure')", in: webView)
            XCTAssertEqual(health.authorizationCount, 1)
            XCTAssertEqual(health.syncRequests.count, 1)
            XCTAssertNil(try store.load())
        }
    }

    @MainActor
    func testCancellingHealthPreviewKeepsTheEmptySnapshot() async throws {
        let health = FakeHealth()
        try await withApplication(health: health) { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            let dayValue = try await self.evaluate("todayKey()", in: webView)
            let day = try XCTUnwrap(dayValue as? String)
            health.syncResult = .success([
                "daily": ["app": "kcal-health", "version": 2,
                          "exportedAt": ISO8601DateFormatter().string(from: Date()),
                          "days": [["date": day, "energy": ["active": 500, "basal": 1500]]]],
                "sleepSamples": NSNull(), "sleepSources": [], "notes": ["Fictional energy only"]
            ])
            try await self.openHealthAndClickSync(in: webView)
            try await self.waitForJavaScript("document.getElementById('alert').classList.contains('on')", in: webView)
            XCTAssertNil(try store.load(), "Previewing imported records must not write")
            _ = try await self.evaluate("Array.from(document.querySelectorAll('#alertBtns button')).find(button => button.textContent === '取消').click(); true", in: webView)
            try await self.waitForJavaScript("!document.getElementById('btnNativeSync').disabled && document.getElementById('nativeSyncStatus').textContent.includes('已取消')", in: webView)
            XCTAssertEqual(health.authorizationCount, 1)
            XCTAssertEqual(health.syncRequests.count, 1)
            XCTAssertNil(try store.load(), "Cancelling must leave the original snapshot untouched")
        }
    }

    @MainActor
    func testSynchronousStorageCompareAndSwapAndReload() async throws {
        let health = FakeHealth()
        try await withApplication(health: health) { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            try await self.assertJavaScript("commitData({settings: {...settings, kcal: 2345}})", equals: true, in: webView)
            let firstRaw = try XCTUnwrap(try store.load())
            var external = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstRaw.utf8)) as? [String: Any])
            var externalSettings = try XCTUnwrap(external["settings"] as? [String: Any])
            XCTAssertEqual(externalSettings["kcal"] as? Int, 2345)
            externalSettings["kcal"] = 2468
            external["settings"] = externalSettings
            let externalRaw = NativeBridge.json(external)
            try store.save(raw: externalRaw, expectedRaw: firstRaw)

            try await self.assertJavaScript("commitData({settings: {...settings, kcal: 1111}})", equals: false, in: webView)
            XCTAssertEqual(try store.load(), externalRaw, "A stale web view cannot overwrite a newer disk snapshot")
            try await self.assertJavaScript("settings.kcal", equals: 2345, in: webView)
            try await self.assertJavaScript("storageStale", equals: true, in: webView)
            try await self.openHealthAndClickSync(in: webView)
            try await self.waitForJavaScript("document.getElementById('nativeSyncStatus').textContent.includes('重新')", in: webView)
            XCTAssertEqual(health.authorizationCount, 0, "Stale storage must stop health import with visible feedback")

            // Mark the old document so readiness cannot accidentally resolve before reload begins.
            _ = try await self.evaluate("window.__nativeIntegrationOldDocument = true; true", in: webView)
            webView.reload()
            try await self.waitForJavaScript("!window.__nativeIntegrationOldDocument && document.readyState === 'complete' && !!window.KcalNative", in: webView)
            _ = try await self.awaitBridgeReady(in: webView)
            try await self.assertJavaScript("settings.kcal", equals: 2468, in: webView)
            try await self.assertJavaScript("storageReadError || storageStale", equals: false, in: webView)
            XCTAssertEqual(try store.load(), externalRaw, "Reload must only read the authoritative snapshot")
            let pong = try await self.bridgeCall("bridge.ping", in: webView)
            XCTAssertEqual(pong["protocolVersion"] as? Int, 2, "Reply delivery must remain connected after reload")
        }
    }

    @MainActor
    func testCorruptSnapshotBlocksHealthImportWithVisibleFeedback() async throws {
        let corrupt = "{synthetic-broken-snapshot"
        let health = FakeHealth()
        try await withApplication(initialRaw: corrupt, health: health) { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            try await self.assertJavaScript("storageReadError", equals: true, in: webView)
            try await self.assertJavaScript("document.getElementById('storageError').hidden", equals: false, in: webView)
            try await self.openHealthAndClickSync(in: webView)
            try await self.waitForJavaScript("document.getElementById('nativeSyncStatus').textContent.includes('读取异常')", in: webView)
            XCTAssertEqual(health.authorizationCount, 0)
            XCTAssertTrue(health.syncRequests.isEmpty)
            XCTAssertEqual(try store.load(), corrupt, "Recovery must preserve the corrupt raw bytes for export")
        }
    }

    @MainActor
    func testDeepSeekRequestUsesTheInjectedAppFallbackChain() async throws {
        let recorder = LauncherRecorder()
        recorder.results = [false, true]
        try await withApplication(recorder: recorder) { controller, store, recorder in
            let webView = try XCTUnwrap(controller.webView)
            let result = try await self.bridgeCall("deepseek.open", in: webView)
            XCTAssertEqual(result["opened"] as? Bool, true)
            XCTAssertEqual(result["target"] as? String, "app")
            XCTAssertEqual(recorder.urls.map { $0.absoluteString }, ["https://applink.deepseek.com/", "dpsk://chat/new"])
            XCTAssertNil(try store.load())
        }
    }

    @MainActor
    func testInvalidNavigationIsRejectedAcrossTheRealBridge() async throws {
        try await withApplication { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            let result = try await self.callAsyncJavaScript("try { await window.KcalNative.call('nav.state', {section: 'invalid', visible: true}); return 'unexpected-success'; } catch (error) { return error.code; }", in: webView)
            XCTAssertEqual(result as? String, "invalid_navigation")
            XCTAssertNil(try store.load())
        }
    }

    @MainActor
    func testWebNavigationFallbackIgnoresLateNativeNavigationStates() async throws {
        try await withApplication { controller, store, _ in
            let webView = try XCTUnwrap(controller.webView)
            let host = try XCTUnwrap(controller.children.first { $0 is UIHostingController<NativeTabBar> } as? UIHostingController<NativeTabBar>)
            try await self.waitForNative("The initial native navigation handshake completes") { !host.view.isHidden }
            try await self.assertJavaScript("getComputedStyle(document.getElementById('primaryNav')).display", equals: "none", in: webView)

            _ = try await self.evaluate("window.KcalNativeNavigation.setEnabled(false); true", in: webView)
            try await self.waitForNative("Fallback disables the native host for this document") { host.view.isHidden }
            try await self.waitForJavaScript("getComputedStyle(document.getElementById('primaryNav')).display !== 'none' && !document.getElementById('primaryNav').hasAttribute('aria-hidden')", in: webView)

            // A previously queued update must never resurrect the native bar over
            // the HTML fallback after the explicit disable has been acknowledged.
            let lateReply = try await self.bridgeCall("nav.state", params: ["section": "health", "visible": true], in: webView)
            XCTAssertEqual(lateReply["accepted"] as? Bool, true)
            XCTAssertTrue(host.view.isHidden, "The document's fallback latch must ignore late native state")
            try await self.assertJavaScript("getComputedStyle(document.getElementById('primaryNav')).display !== 'none'", equals: true, in: webView)
            XCTAssertNil(try store.load(), "Navigation fallback must not modify records")
        }
    }

    @MainActor
    func testNativeNavigationLayoutRoutingAndPresentationStates() async throws {
        let configurations: [(String, CGSize, UIUserInterfaceStyle, UIContentSizeCategory)] = [
            ("narrow-light", CGSize(width: 320, height: 740), .light, .large),
            ("phone-dark", CGSize(width: 393, height: 852), .dark, .large),
            ("accessibility-light", CGSize(width: 393, height: 852), .light, .accessibilityExtraExtraExtraLarge)
        ]
        for (name, viewport, style, textSize) in configurations {
            try await withApplication(viewport: viewport, style: style, contentSize: textSize) { controller, store, _ in
                let webView = try XCTUnwrap(controller.webView)
                let host = try XCTUnwrap(controller.children.first { $0 is UIHostingController<NativeTabBar> } as? UIHostingController<NativeTabBar>)
                try await self.waitForNative("Native navigation appears after the web handshake") { !host.view.isHidden && host.view.bounds.height > 0 }
                controller.view.layoutIfNeeded()
                XCTAssertEqual(controller.view.bounds.width, viewport.width, accuracy: 0.5)
                XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, textSize)
                XCTAssertEqual(host.traitCollection.userInterfaceStyle, style)
                try await self.assertJavaScript("getComputedStyle(document.getElementById('primaryNav')).display", equals: "none", in: webView)
                try await self.assertJavaScript("Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) <= innerWidth", equals: true, in: webView)
                let frame = host.view.frame
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, controller.view.bounds.width + 0.5)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom + 0.5)
                XCTAssertGreaterThanOrEqual(frame.height, 56)

                // Invoke exactly the action used by the native SwiftUI buttons; HTML links
                // still own the actual route transition and confirmed selected section.
                host.rootView.state.onSelect?("health")
                try await self.waitForJavaScript("!document.getElementById('healthPage').hidden", in: webView)
                try await self.waitForNative("Native selection follows the confirmed health route") { host.rootView.state.section == "health" }
                host.rootView.state.onSelect?("diet")
                try await self.waitForJavaScript("document.getElementById('healthPage').hidden", in: webView)
                try await self.waitForNative("Native selection follows the confirmed diet route") { host.rootView.state.section == "diet" }

                _ = try await self.evaluate("openSet(); true", in: webView)
                try await self.waitForNative("The native bar hides behind the settings modal") { host.view.isHidden }
                try await self.assertJavaScript("document.getElementById('dlg').classList.contains('on')", equals: true, in: webView)
                _ = try await self.evaluate("closeSet(); true", in: webView)
                try await self.waitForNative("Closing the modal restores native navigation") { !host.view.isHidden }

                // Exercise the same UIKit notification path as a keyboard without opening
                // a system keyboard or relying on simulator hardware-keyboard preferences.
                let keyboardFrame = controller.view.convert(CGRect(x: 0, y: controller.view.bounds.height - 220,
                    width: controller.view.bounds.width, height: 220), to: nil)
                NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                    userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboardFrame)])
                try await self.waitForNative("A keyboard covering the web content hides navigation") { host.view.isHidden }
                NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
                try await self.waitForNative("Keyboard dismissal restores navigation") { !host.view.isHidden }
                XCTAssertNil(try store.load(), "Layout, routing and presentation must stay read-only")

                // These are real rendered UIKit/SwiftUI/WebKit attachments for human review;
                // the assertions intentionally do not claim to validate glass pixels.
                controller.view.layoutIfNeeded()
                await Task.yield()
                var rendered = false
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    rendered = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                XCTAssertTrue(rendered, "The screenshot must include the displayed view hierarchy")
                let attachment = XCTAttachment(image: image)
                attachment.name = "Native-navigation-" + name
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
        }
    }

    @MainActor
    private func withApplication(initialRaw: String? = nil, health: FakeHealth = FakeHealth(), recorder: LauncherRecorder = LauncherRecorder(), viewport: CGSize? = nil, style: UIUserInterfaceStyle = .unspecified, contentSize: UIContentSizeCategory? = nil, body: @MainActor (WebViewController, SnapshotStore, LauncherRecorder) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KcalNativeIntegration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let initialRaw {
            try Data(initialRaw.utf8).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        }
        let store = SnapshotStore(directory: directory)
        let defaults = UserDefaults.standard
        let keys = ["kcal.native.autoSync", "kcal.native.sleepSource"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defaults.set(false, forKey: keys[0])
        defaults.removeObject(forKey: keys[1])
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let controller = WebViewController(store: store, health: health, launcher: recorder.makeLauncher())
        let container = UIViewController()
        container.overrideUserInterfaceStyle = style
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            controller.webView?.stopLoading()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        container.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(controller.view)
        if let viewport {
            NSLayoutConstraint.activate([
                controller.view.widthAnchor.constraint(equalToConstant: viewport.width),
                controller.view.heightAnchor.constraint(equalToConstant: viewport.height),
                controller.view.centerXAnchor.constraint(equalTo: container.view.centerXAnchor),
                controller.view.centerYAnchor.constraint(equalTo: container.view.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ])
        }
        controller.didMove(toParent: container)
        if let contentSize {
            container.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: contentSize), forChild: controller)
        }
        container.view.layoutIfNeeded()
        controller.loadViewIfNeeded()
        let webView = try XCTUnwrap(controller.webView)
        try await waitForJavaScript("document.readyState === 'complete' && !!window.KcalNative && !!document.getElementById('btnNativeSync')", in: webView)
        _ = try await awaitBridgeReady(in: webView)
        try await body(controller, store, recorder)
    }

    @MainActor
    private func openHealthAndClickSync(in webView: WKWebView) async throws {
        _ = try await evaluate("document.getElementById('navHealth').click(); true", in: webView)
        try await waitForJavaScript("!document.getElementById('healthPage').hidden && !document.getElementById('btnNativeSync').disabled", in: webView)
        _ = try await evaluate("document.getElementById('btnNativeSync').click(); true", in: webView)
    }

    @MainActor
    private func status(in webView: WKWebView) async throws -> String {
        let result = try await evaluate("document.getElementById('nativeSyncStatus').textContent", in: webView)
        return try XCTUnwrap(result as? String)
    }

    @MainActor
    private func awaitBridgeReady(in webView: WKWebView) async throws -> Any {
        try await callAsyncJavaScript("await window.KcalNative.ready; return await window.KcalNative.call('bridge.ping');", in: webView)
    }

    @MainActor
    private func bridgeCall(_ method: String, params: [String: Any] = [:], in webView: WKWebView) async throws -> [String: Any] {
        let result = try await callAsyncJavaScript("return await window.KcalNative.call(method, params);", arguments: ["method": method, "params": params], in: webView)
        return try XCTUnwrap(result as? [String: Any])
    }

    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    @MainActor
    private func callAsyncJavaScript(_ script: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> Any {
        let bounded = "var timeout; try { return await Promise.race([(async () => { " + script + " })(), new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Native integration request timed out')), 15000); })]); } finally { clearTimeout(timeout); }"
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(bounded, arguments: arguments, in: nil, contentWorld: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    @MainActor
    private func assertJavaScript<T: Equatable>(_ script: String, equals expected: T, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await evaluate(script, in: webView)
        XCTAssertEqual(result as? T, .some(expected), file: file, line: line)
    }

    @MainActor
    private func waitForJavaScript(_ predicate: String, in webView: WKWebView, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await evaluate("Boolean(" + predicate + ")", in: webView), value as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "KcalAnalysis.NativeBridgeIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for WebKit condition: " + predicate])
    }

    @MainActor
    private func waitForNative(_ description: String, timeout: TimeInterval = 5, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "KcalAnalysis.NativeBridgeIntegration", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
