import XCTest
import SwiftUI
import UIKit
@testable import KcalAnalysis

/// Every provider is synthetic. These tests never request real HealthKit access,
/// read a health store, or write the application's snapshot/UserDefaults.
final class NativeHealthSyncTests: XCTestCase {
    typealias Completion = (Result<[String: Any], Error>) -> Void

    private class FakeHealth: NativeHealthProviding {
        var isAvailable = true
        var authorizationCount = 0
        var syncRequests: [[String: Any]] = []
        var heldAuthorization = false
        var heldRead = false
        var authorizations: [Completion] = []
        var reads: [Completion] = []
        var authorizationResult: Result<[String: Any], Error> = .success(["requestCompleted": true])
        var readResult: Result<[String: Any], Error> = .success([
            "daily": NSNull(), "sleepSamples": NSNull(), "sleepSources": [], "notes": ["虚构测试，没有真实健康数据。"]
        ])
        var authorizationWasOnMain = false

        func authorize(completion: @escaping Completion) {
            authorizationCount += 1
            authorizationWasOnMain = Thread.isMainThread
            authorizations.append(completion)
            if !heldAuthorization { completion(authorizationResult) }
        }
        func sync(params: [String: Any], completion: @escaping Completion) {
            syncRequests.append(params)
            reads.append(completion)
            if !heldRead { completion(readResult) }
        }
    }

    private final class DiagnosticHealth: FakeHealth, NativeHealthDiagnosticProviding {
        var diagnosticResult: Result<[String: Any], Error> = .success([
            "authorizationRequestStatus": "unnecessary", "healthAvailable": true, "usageDescriptionPresent": true
        ])
        var heldDiagnostic = false
        func diagnostics(completion: @escaping Completion) {
            if !heldDiagnostic { completion(diagnosticResult) }
        }
    }

    @MainActor
    func testInitialAndProtectedStatesNeverCallHealthOrSave() async throws {
        let health = FakeHealth()
        var previews = 0
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in
            previews += 1
            return self.preview()
        }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(health.authorizationCount, 0)
        XCTAssertEqual(previews, 0)
        let protected = NativeHealthSyncModel(health: health, storageIssue: "虚构存储校验失败", defaults: nil) { _, _, _ in self.preview() }
        protected.start()
        XCTAssertEqual(protected.phase, .failed)
        XCTAssertFalse(protected.canStart)
        XCTAssertTrue(protected.errorText?.contains("虚构存储校验失败") == true)
        XCTAssertEqual(health.authorizationCount, 0)
        XCTAssertEqual(previews, 0)
    }

    @MainActor
    func testAuthorizationImmediatelyPersistsProgressAndRequiresExplicitCommit() async throws {
        let health = FakeHealth()
        health.heldAuthorization = true
        var commits = 0
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in
            NativeHealthReview(title: "1 项虚构更新", details: ["虚构日期"], canCommit: true) {
                commits += 1
                return "虚构保存完成"
            }
        }
        model.start()
        XCTAssertEqual(model.phase, .authorizing)
        XCTAssertTrue(model.message.contains("授权"))
        XCTAssertTrue(health.authorizationWasOnMain)
        XCTAssertTrue(model.authorizationPending)
        model.start()
        XCTAssertEqual(health.authorizationCount, 1)
        XCTAssertEqual(health.syncRequests.count, 0)
        health.authorizations[0](.success(["requestCompleted": true]))
        try await eventually { model.phase == .ready }
        XCTAssertEqual(commits, 0)
        XCTAssertTrue(model.canCommit)
        XCTAssertEqual(health.syncRequests.count, 1)
        model.confirmImport()
        model.confirmImport()
        try await eventually { model.phase == .saved }
        XCTAssertEqual(commits, 1)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.message, "虚构保存完成")
    }

    @MainActor
    func testEmptyResultsCannotSaveAndDoNotClaimReadAuthorization() async throws {
        let health = DiagnosticHealth()
        var commits = 0
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in
            NativeHealthReview(title: "没有更新", details: [], canCommit: false) { commits += 1; return "invalid" }
        }
        model.start()
        try await eventually { model.phase == .ready }
        XCTAssertFalse(model.canCommit)
        XCTAssertTrue(model.message.contains("没有可保存"))
        XCTAssertTrue(model.diagnostics.contains { $0.contains("不代表已获读取权限") })
        model.confirmImport()
        XCTAssertEqual(commits, 0)
        // Status .unnecessary never skips the actual authorization request.
        XCTAssertEqual(health.authorizationCount, 1)
    }

    @MainActor
    func testAuthorizationFailureKeepsDomainCodeAndUnderlyingCauseVisible() async throws {
        let health = FakeHealth()
        let cause = NSError(domain: "SyntheticSigning", code: 93, userInfo: [NSLocalizedDescriptionKey: "虚构签名错误"])
        health.authorizationResult = .failure(NSError(domain: "SyntheticHealthKit", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "虚构授权错误", NSUnderlyingErrorKey: cause]))
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in self.preview() }
        model.start()
        try await eventually { model.phase == .failed }
        XCTAssertTrue(model.errorText?.contains("SyntheticHealthKit / 4") == true)
        XCTAssertTrue(model.errorText?.contains("SyntheticSigning / 93") == true)
        XCTAssertTrue(health.syncRequests.isEmpty)
        XCTAssertNil(model.review)
        XCTAssertFalse(model.authorizationPending)
        await Task.yield()
        XCTAssertEqual(model.phase, .failed, "Errors persist until a new user action; no transient toast")
    }

    @MainActor
    func testReadFailureAndStorageCommitFailureRemainVisible() async throws {
        let health = FakeHealth()
        health.readResult = .failure(NSError(domain: "SyntheticQuery", code: 7))
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in self.preview() }
        model.start()
        try await eventually { model.phase == .failed }
        XCTAssertTrue(model.errorText?.contains("SyntheticQuery / 7") == true)
        XCTAssertFalse(model.canCommit)

        let saveModel = NativeHealthSyncModel(health: FakeHealth(), defaults: nil) { _, _, _ in
            NativeHealthReview(title: "虚构预览", details: [], canCommit: true) {
                throw NSError(domain: "SyntheticCAS", code: 409, userInfo: [NSLocalizedDescriptionKey: "快照已改变"])
            }
        }
        saveModel.start()
        try await eventually { saveModel.phase == .ready }
        saveModel.confirmImport()
        try await eventually { saveModel.phase == .failed }
        XCTAssertTrue(saveModel.errorText?.contains("SyntheticCAS / 409") == true)
        XCTAssertNil(saveModel.review, "A failed commit requires a new preview")
    }

    @MainActor
    func testNeverReturningAuthorizationTimesOutAndLateSuccessDoesNotRead() async throws {
        let health = FakeHealth()
        health.heldAuthorization = true
        let model = NativeHealthSyncModel(health: health,
            timeouts: .init(authorization: 0.02), defaults: nil) { _, _, _ in self.preview() }
        model.start()
        try await eventually { model.phase == .failed }
        XCTAssertTrue(model.errorText?.contains("timeout.authorizing") == true)
        XCTAssertTrue(model.authorizationPending)
        XCTAssertFalse(model.canStart, "Do not issue a second authorization while the system request is outstanding")
        model.start()
        XCTAssertEqual(health.authorizationCount, 1)
        health.authorizations[0](.success([:]))
        try await eventually { !model.authorizationPending }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.canStart)
        XCTAssertTrue(health.syncRequests.isEmpty, "Late authorization must not resume an expired operation")
    }

    @MainActor
    func testReadTimeoutIgnoresLateResultAfterRetry() async throws {
        let health = FakeHealth()
        health.heldRead = true
        var previews = 0
        let model = NativeHealthSyncModel(health: health, timeouts: .init(read: 0.1), defaults: nil) { _, _, _ in
            previews += 1
            return self.preview()
        }
        model.start()
        try await eventually { model.phase == .failed }
        XCTAssertTrue(model.errorText?.contains("timeout.reading") == true)
        let oldRead = try XCTUnwrap(health.reads.first)
        model.start()
        try await eventually { health.reads.count == 2 }
        oldRead(.success([:]))
        await Task.yield()
        XCTAssertEqual(previews, 0)
        health.reads[1](.success([:]))
        try await eventually { model.phase == .ready }
        XCTAssertEqual(previews, 1)
    }

    @MainActor
    func testDiagnosticFailureAndTimeoutDoNotContinueAuthorization() async throws {
        let health = DiagnosticHealth()
        health.diagnosticResult = .failure(NSError(domain: "SyntheticDiagnostic", code: 8))
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in self.preview() }
        model.start()
        try await eventually { model.phase == .failed }
        XCTAssertTrue(model.errorText?.contains("SyntheticDiagnostic / 8") == true)
        XCTAssertEqual(health.authorizationCount, 0)

        let held = DiagnosticHealth()
        held.heldDiagnostic = true
        let timed = NativeHealthSyncModel(health: held, timeouts: .init(diagnostic: 0.02), defaults: nil) { _, _, _ in self.preview() }
        timed.start()
        try await eventually { timed.phase == .failed }
        XCTAssertTrue(timed.errorText?.contains("timeout.checking") == true)
        XCTAssertEqual(held.authorizationCount, 0)
    }

    @MainActor
    func testReviewTimeoutIgnoresAnEventuallyPreparedReview() async throws {
        var pending: CheckedContinuation<NativeHealthReview, Never>?
        let model = NativeHealthSyncModel(health: FakeHealth(), timeouts: .init(review: 0.05), defaults: nil) { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        model.start()
        try await eventually { model.phase == .failed && pending != nil }
        XCTAssertTrue(model.errorText?.contains("timeout.reviewing") == true)
        pending?.resume(returning: preview())
        pending = nil
        await Task.yield()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.review)
        XCTAssertFalse(model.canCommit)
    }

    @MainActor
    func testSavingCannotBeCancelledOrConfirmedTwice() async throws {
        var pending: CheckedContinuation<String, Never>?
        var commits = 0
        let model = NativeHealthSyncModel(health: FakeHealth(), defaults: nil) { _, _, _ in
            NativeHealthReview(title: "虚构记录", details: [], canCommit: true) {
                commits += 1
                return await withCheckedContinuation { pending = $0 }
            }
        }
        model.start()
        try await eventually { model.phase == .ready }
        model.confirmImport()
        try await eventually { pending != nil }
        model.cancel()
        model.confirmImport()
        XCTAssertEqual(model.phase, .saving)
        XCTAssertFalse(model.canClose)
        XCTAssertEqual(commits, 1)
        pending?.resume(returning: "保存完成")
        pending = nil
        try await eventually { model.phase == .saved }
        XCTAssertEqual(model.message, "保存完成")
    }

    @MainActor
    func testCancelAndDuplicateCallbacksCannotPrepareOrSaveTwice() async throws {
        let health = FakeHealth()
        health.heldRead = true
        var previews = 0
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in
            previews += 1
            return self.preview()
        }
        model.start()
        try await eventually { health.reads.count == 1 }
        model.cancel()
        health.reads[0](.success([:]))
        await Task.yield()
        XCTAssertEqual(previews, 0)
        XCTAssertNil(model.review)
        model.start()
        try await eventually { health.reads.count == 2 }
        health.reads[1](.success([:]))
        health.reads[1](.failure(NSError(domain: "duplicate", code: 1)))
        try await eventually { model.phase == .ready }
        XCTAssertEqual(previews, 1)
        XCTAssertNil(model.errorText)
        model.cancel()
        XCTAssertFalse(model.canCommit)
    }

    @MainActor
    func testDateValidationAndSourceChangesRequireNewPreview() async throws {
        let health = FakeHealth()
        health.readResult = .success(["sleepSources": [["id": "watch-a", "name": "虚构手表 A"], ["id": "watch-b", "name": "虚构手表 B"]]])
        let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in self.preview() }
        model.fromDate = Calendar.current.date(byAdding: .day, value: 1, to: model.throughDate)!
        model.start()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(health.authorizationCount, 0)
        model.fromDate = model.throughDate
        model.start()
        try await eventually { model.phase == .ready }
        XCTAssertEqual(model.sources.count, 2)
        model.selectedSleepSource = "watch-b"
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.review)
        model.start()
        try await eventually { model.phase == .ready }
        XCTAssertEqual(health.syncRequests.last?["sleepSource"] as? String, "watch-b")
        model.fromDate = Calendar.current.date(byAdding: .day, value: -1, to: model.fromDate)!
        XCTAssertFalse(model.canCommit)
    }

    @MainActor
    func testSleepPreferencePersistsWithoutChangingExistingAutoSyncChoice() async throws {
        let suite = "NativeHealthSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-source", forKey: "kcal.native.sleepSource")
        defaults.set(true, forKey: "kcal.native.autoSync")
        let health = FakeHealth()
        let model = NativeHealthSyncModel(health: health, defaults: defaults) { _, _, _ in self.preview() }
        XCTAssertEqual(model.selectedSleepSource, "old-source")
        XCTAssertEqual(model.sources.first?.id, "old-source")
        XCTAssertTrue(model.automaticRefreshEnabled)
        XCTAssertEqual(health.authorizationCount, 0, "Opening the screen must not silently ask for health access")
        model.selectedSleepSource = "new-source"
        XCTAssertEqual(defaults.string(forKey: "kcal.native.sleepSource"), "new-source")
        XCTAssertTrue(defaults.bool(forKey: "kcal.native.autoSync"))
        model.selectedSleepSource = ""
        XCTAssertNil(defaults.object(forKey: "kcal.native.sleepSource"))
        model.setAutomaticRefreshEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: "kcal.native.autoSync"))
        XCTAssertEqual(health.authorizationCount, 0, "Changing stored preferences alone must not request HealthKit access")
    }

    @MainActor
    func testAutomaticRefreshRequiresStoredOptInAndCurrentInteractionPermission() async throws {
        let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let health = FakeHealth()
        var canApply = false
        var commits = 0
        let model = NativeHealthAutoSyncModel(health: health, defaults: defaults, canApply: { canApply }) { _, _, _ in
            NativeHealthAutomaticReview(updates: 1, conflicts: 0) { commits += 1; return "虚构刷新完成" }
        }
        model.refreshIfEnabled(allowed: true)
        defaults.set(true, forKey: "kcal.native.autoSync")
        model.refreshIfEnabled(allowed: true)
        canApply = true
        model.refreshIfEnabled(allowed: false)
        XCTAssertTrue(health.syncRequests.isEmpty)
        model.refreshIfEnabled(allowed: true)
        try await eventually { !model.isRunning }
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(health.syncRequests.count, 1)
        XCTAssertEqual(health.authorizationCount, 0)
        XCTAssertEqual(model.message, "虚构刷新完成")
    }

    @MainActor
    func testAutomaticRefreshKeepsSevenDayWindowSourceAndSixtySecondThrottle() async throws {
        let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kcal.native.autoSync")
        defaults.set("synthetic-watch", forKey: "kcal.native.sleepSource")
        let calendar = Calendar(identifier: .gregorian)
        var now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 11, day: 10, hour: 12)))
        let health = FakeHealth()
        let model = NativeHealthAutoSyncModel(health: health, defaults: defaults, now: { now }) { _, from, through in
            XCTAssertEqual(from, "2025-11-04")
            XCTAssertEqual(through, "2025-11-10")
            return NativeHealthAutomaticReview(updates: 0, conflicts: 0) { XCTFail("No updates must not save"); return "" }
        }
        model.refreshIfEnabled(allowed: true)
        try await eventually { !model.isRunning }
        XCTAssertEqual(health.syncRequests.first?["sleepSource"] as? String, "synthetic-watch")
        model.refreshIfEnabled(allowed: true)
        now = now.addingTimeInterval(59)
        model.refreshIfEnabled(allowed: true)
        XCTAssertEqual(health.syncRequests.count, 1)
        now = now.addingTimeInterval(1)
        model.refreshIfEnabled(allowed: true)
        try await eventually { !model.isRunning }
        XCTAssertEqual(health.syncRequests.count, 2)
        XCTAssertEqual(health.authorizationCount, 0)
    }

    @MainActor
    func testAutomaticConflictsNeverCommitAndDirectUserToManualPreview() async throws {
        let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kcal.native.autoSync")
        let model = NativeHealthAutoSyncModel(health: FakeHealth(), defaults: defaults) { _, _, _ in
            NativeHealthAutomaticReview(updates: 3, conflicts: 1) { XCTFail("Automatic refresh cannot overwrite a manual record"); return "" }
        }
        model.refreshIfEnabled(allowed: true)
        try await eventually { !model.isRunning }
        XCTAssertTrue(model.message?.contains("本次自动刷新未写入") == true)
        XCTAssertNil(model.errorText)
    }

    @MainActor
    func testAutomaticCancellationRejectsLateHealthResult() async throws {
        let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kcal.native.autoSync")
        let health = FakeHealth()
        health.heldRead = true
        var previews = 0
        let model = NativeHealthAutoSyncModel(health: health, defaults: defaults) { _, _, _ in
            previews += 1
            return NativeHealthAutomaticReview(updates: 1, conflicts: 0) { XCTFail("Cancelled work cannot save"); return "" }
        }
        model.refreshIfEnabled(allowed: true)
        XCTAssertTrue(model.isRunning)
        model.cancel()
        health.reads[0](.success([:]))
        await Task.yield()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(previews, 0)
    }

    @MainActor
    func testAutomaticResultRechecksOptInAndEditingStateBeforePreview() async throws {
        for disablePreference in [false, true] {
            let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "kcal.native.autoSync")
            let health = FakeHealth()
            health.heldRead = true
            var allowed = true
            let model = NativeHealthAutoSyncModel(health: health, defaults: defaults, canApply: { allowed }) { _, _, _ in
                XCTFail("A result arriving while disabled or editing cannot prepare a save")
                return NativeHealthAutomaticReview(updates: 1, conflicts: 0) { "" }
            }
            model.refreshIfEnabled(allowed: true)
            if disablePreference { defaults.set(false, forKey: "kcal.native.autoSync") }
            else { allowed = false }
            health.reads[0](.success([:]))
            try await eventually { !model.isRunning }
            XCTAssertTrue(model.message?.contains("未保存") == true)
        }
    }

    @MainActor
    func testAutomaticRefreshRechecksPermissionBetweenPreviewAndAtomicSave() async throws {
        let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kcal.native.autoSync")
        var allowed = true
        let model = NativeHealthAutoSyncModel(health: FakeHealth(), defaults: defaults, canApply: { allowed }) { _, _, _ in
            allowed = false
            return NativeHealthAutomaticReview(updates: 1, conflicts: 0) { XCTFail("Permission changed while preparing review"); return "" }
        }
        model.refreshIfEnabled(allowed: true)
        try await eventually { !model.isRunning }
        XCTAssertTrue(model.message?.contains("未保存") == true)
    }

    @MainActor
    func testAutomaticTimeoutRetryIgnoresOldResultAndNeverAuthorizes() async throws {
        let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kcal.native.autoSync")
        let health = FakeHealth()
        health.heldRead = true
        var now = Date()
        var commits = 0
        let model = NativeHealthAutoSyncModel(health: health, defaults: defaults, now: { now }, timeout: 0.1) { _, _, _ in
            NativeHealthAutomaticReview(updates: 1, conflicts: 0) { commits += 1; return "虚构刷新完成" }
        }
        model.refreshIfEnabled(allowed: true)
        try await eventually { !model.isRunning }
        XCTAssertTrue(model.errorText?.contains("timeout.automatic") == true)
        now = now.addingTimeInterval(61)
        model.refreshIfEnabled(allowed: true)
        XCTAssertEqual(health.reads.count, 2)
        health.reads[0](.success([:]))
        await Task.yield()
        XCTAssertEqual(commits, 0)
        health.reads[1](.success([:]))
        try await eventually { !model.isRunning }
        XCTAssertEqual(commits, 1)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(health.authorizationCount, 0)
    }

    @MainActor
    func testAutomaticQueryAndAtomicSaveFailuresRemainVisible() async throws {
        for queryFails in [false, true] {
            let suite = "NativeHealthAutoSyncTests-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "kcal.native.autoSync")
            let health = FakeHealth()
            if queryFails { health.readResult = .failure(NSError(domain: "SyntheticAutoQuery", code: 17)) }
            let model = NativeHealthAutoSyncModel(health: health, defaults: defaults) { _, _, _ in
                NativeHealthAutomaticReview(updates: 1, conflicts: 0) { throw NSError(domain: "SyntheticAutoCAS", code: 409) }
            }
            model.refreshIfEnabled(allowed: true)
            try await eventually { !model.isRunning }
            XCTAssertTrue(model.errorText?.contains(queryFails ? "SyntheticAutoQuery / 17" : "SyntheticAutoCAS / 409") == true)
            XCTAssertEqual(health.authorizationCount, 0)
        }
    }

    @MainActor
    func testNativeDateControlsHaveSeparateRowsAcrossScreenAndTextSizes() async throws {
        for (name, width, height, style, typeSize) in [
            ("320-light", CGFloat(320), CGFloat(812), UIUserInterfaceStyle.light, DynamicTypeSize.large),
            ("393-dark", CGFloat(393), CGFloat(852), UIUserInterfaceStyle.dark, DynamicTypeSize.large),
            ("320-largest-text", CGFloat(320), CGFloat(1_500), UIUserInterfaceStyle.light, DynamicTypeSize.accessibility5)
        ] {
            let health = FakeHealth()
            let model = NativeHealthSyncModel(health: health, defaults: nil) { _, _, _ in self.preview() }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let parent = UIViewController()
            let host = UIHostingController(rootView: NavigationStack {
                NativeHealthSyncView(model: model, onClose: {})
            }.environment(\.dynamicTypeSize, typeSize).environment(\.locale, Locale(identifier: "zh_CN")))
            window.rootViewController = parent
            window.frame = scene.coordinateSpace.bounds
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            parent.overrideUserInterfaceStyle = style
            parent.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            parent.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.widthAnchor.constraint(equalToConstant: width),
                host.view.heightAnchor.constraint(equalToConstant: height),
                host.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
                host.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor)
            ])
            host.didMove(toParent: parent)
            parent.view.layoutIfNeeded()
            try await eventually { self.descendants(host.view).compactMap { $0 as? UIDatePicker }.count == 2 }
            host.view.layoutIfNeeded()
            let controls = descendants(host.view).compactMap { $0 as? UIDatePicker }
            let frames = controls.map { $0.convert($0.bounds, to: host.view) }.sorted { $0.minY < $1.minY }
            XCTAssertEqual(frames.count, 2)
            XCTAssertGreaterThan(frames[0].height, 0)
            XCTAssertLessThanOrEqual(frames[0].maxY, frames[1].minY, "Native date controls must not overlap at \(name)")
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 1, "Date control must fit the available width")
            }
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Native-health-date-rows-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(health.authorizationCount, 0)
            XCTAssertTrue(health.syncRequests.isEmpty)
        }
    }

    @MainActor private func preview() -> NativeHealthReview {
        NativeHealthReview(title: "虚构预览", details: [], canCommit: true) { "虚构保存" }
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Native health state/layout did not reach its expected condition")
        throw NSError(domain: "NativeHealthSyncTests", code: 1)
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
