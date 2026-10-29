import XCTest
import UIKit
@testable import KcalAnalysis

final class ExternalAppLauncherTests: XCTestCase {
    private final class Recorder {
        struct Call {
            let url: URL
            let options: [UIApplication.OpenExternalURLOptionsKey: Any]
        }
        var calls: [Call] = []
        var results: [Bool]

        init(_ results: [Bool]) { self.results = results }

        func open(_ url: URL, options: [UIApplication.OpenExternalURLOptionsKey: Any], completion: @escaping (Bool) -> Void) {
            calls.append(Call(url: url, options: options))
            guard !results.isEmpty else { XCTFail("Unexpected URL open: \(url)"); completion(false); return }
            completion(results.removeFirst())
        }

        func launcher() -> ExternalAppLauncher {
            ExternalAppLauncher(opener: { self.open($0, options: $1, completion: $2) })
        }
    }

    private let defaultURLs = ["https://applink.deepseek.com/", "dpsk://chat/new", "https://chat.deepseek.com/"]

    private func assertSuccess(_ result: Result<[String: Any], Error>, target: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let value = try result.get()
            XCTAssertEqual(value["opened"] as? Bool, true, file: file, line: line)
            XCTAssertEqual(value["target"] as? String, target, file: file, line: line)
        } catch { XCTFail("Expected successful URL open, got \(error)", file: file, line: line) }
    }

    func testUniversalLinkSuccessStopsBeforeFallbacks() {
        let recorder = Recorder([true])
        var completions = 0
        recorder.launcher().openDeepSeek { result in
            completions += 1
            self.assertSuccess(result, target: "app")
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, Array(defaultURLs.prefix(1)))
        XCTAssertEqual(recorder.calls.first?.options[.universalLinksOnly] as? Bool, true)
    }

    func testSchemeFallbackOpensAppWhenUniversalLinkFails() {
        let recorder = Recorder([false, true])
        recorder.launcher().openDeepSeek { self.assertSuccess($0, target: "app") }
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, Array(defaultURLs.prefix(2)))
        XCTAssertEqual(recorder.calls[0].options[.universalLinksOnly] as? Bool, true)
        XCTAssertTrue(recorder.calls[1].options.isEmpty)
    }

    func testWebsiteFallbackAfterBothAppEntriesFail() {
        let recorder = Recorder([false, false, true])
        recorder.launcher().openDeepSeek { self.assertSuccess($0, target: "web") }
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, defaultURLs)
        XCTAssertTrue(recorder.calls[2].options.isEmpty)
    }

    func testAllFailuresCompleteOnceWithActionableError() {
        let recorder = Recorder([false, false, false])
        var completions = 0
        recorder.launcher().openDeepSeek { result in
            completions += 1
            switch result {
            case .success: XCTFail("Every URL open failed")
            case .failure(let error):
                XCTAssertEqual((error as? NativeFailure)?.code, "cannot_open")
                XCTAssertTrue(error.localizedDescription.contains("手动"))
            }
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, defaultURLs)
    }

    func testValidCustomLinkIsTriedFirst() {
        let recorder = Recorder([true])
        recorder.launcher().openDeepSeek(preferred: "  custom-ai://conversation  ") { self.assertSuccess($0, target: "custom") }
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, ["custom-ai://conversation"])
        XCTAssertTrue(recorder.calls[0].options.isEmpty)
    }

    func testCustomLinkFailureUsesCompleteDefaultChain() {
        let recorder = Recorder([false, false, false, true])
        recorder.launcher().openDeepSeek(preferred: "custom-ai://conversation") { self.assertSuccess($0, target: "web") }
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, ["custom-ai://conversation"] + defaultURLs)
        XCTAssertEqual(recorder.calls[1].options[.universalLinksOnly] as? Bool, true)
    }

    func testExplicitDefaultSchemeIsNotRetriedAfterItsFailure() {
        let recorder = Recorder([false, false, true])
        recorder.launcher().openDeepSeek(preferred: "dpsk://chat/new") { self.assertSuccess($0, target: "web") }
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, ["dpsk://chat/new", "https://applink.deepseek.com/", "https://chat.deepseek.com/"])
        XCTAssertEqual(recorder.calls[1].options[.universalLinksOnly] as? Bool, true)
    }

    func testStoredDefaultWebsiteAndAppDomainStillUseAppOnlyRouting() {
        for preferred in ["https://chat.deepseek.com/", "https://chat.deepseek.com", " HTTPS://CHAT.DEEPSEEK.COM:443/ ", "https://applink.deepseek.com/"] {
            let recorder = Recorder([true])
            recorder.launcher().openDeepSeek(preferred: preferred) { self.assertSuccess($0, target: "app") }
            XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, Array(defaultURLs.prefix(1)), preferred)
            XCTAssertEqual(recorder.calls[0].options[.universalLinksOnly] as? Bool, true, preferred)
        }
    }

    func testExplicitWebPathRemainsAValidCustomOverride() {
        let recorder = Recorder([true])
        recorder.launcher().openDeepSeek(preferred: "https://chat.deepseek.com/custom/path") { self.assertSuccess($0, target: "custom") }
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, ["https://chat.deepseek.com/custom/path"])
        XCTAssertTrue(recorder.calls[0].options.isEmpty)
    }

    func testInvalidOrDangerousPreferredLinkIsNeverOpened() {
        let invalid = ["", "  ", "/relative/path", "file:///private/data", "javascript:alert(1)", "DATA:text/plain,test", "blob:https://example.com/id", "about:blank", "kcalapp://localhost/index.html", "applewebdata://local", "https://", "https://user:password@example.com/", "custom://user:secret@host", "https://exam\nple.com/", "custom://" + String(repeating: "a", count: 8192)]
        for preferred in invalid {
            let recorder = Recorder([true])
            recorder.launcher().openDeepSeek(preferred: preferred) { self.assertSuccess($0, target: "app") }
            XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, Array(defaultURLs.prefix(1)), preferred)
        }
    }

    func testOrdinaryExternalLinksKeepSystemRoutingOptions() {
        for value in ["https://example.com/help", "mailto:help@example.com", "custom-ai://conversation"] {
            let recorder = Recorder([true])
            var opened = false
            recorder.launcher().openExternal(URL(string: value)!) { opened = $0 }
            XCTAssertTrue(opened, value)
            XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, [value])
            XCTAssertTrue(recorder.calls[0].options.isEmpty)
        }
    }

    func testOrdinaryExternalFailureDoesNotStartDeepSeekFallbacks() {
        let recorder = Recorder([false])
        var result: Bool?
        recorder.launcher().openExternal(URL(string: "https://example.com/help")!) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(recorder.calls.map { $0.url.absoluteString }, ["https://example.com/help"])
    }

    func testFallbackWaitsForEachAsynchronousOpenResult() {
        var urls: [String] = []
        var pending: [(Bool) -> Void] = []
        let launcher = ExternalAppLauncher { url, _, complete in
            urls.append(url.absoluteString)
            pending.append(complete)
        }
        var completions = 0
        launcher.openDeepSeek { result in
            completions += 1
            self.assertSuccess(result, target: "app")
        }
        XCTAssertEqual(urls, Array(defaultURLs.prefix(1)))
        XCTAssertEqual(completions, 0)
        pending.removeFirst()(false)
        XCTAssertEqual(urls, Array(defaultURLs.prefix(2)))
        XCTAssertEqual(completions, 0)
        pending.removeFirst()(true)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnsafeOrdinaryExternalLinksAreRejectedBeforeSystemOpen() {
        for value in ["/relative/path", "file:///private/data", "javascript:alert(1)", "data:text/plain,test", "blob:https://example.com/id", "about:blank", "kcalapp://localhost/index.html", "applewebdata://local", "https://", "https://user:password@example.com/"] {
            let recorder = Recorder([])
            guard let url = URL(string: value) else { continue }
            var result: Bool?
            recorder.launcher().openExternal(url) { result = $0 }
            XCTAssertEqual(result, false, value)
            XCTAssertTrue(recorder.calls.isEmpty, value)
        }
    }
}
