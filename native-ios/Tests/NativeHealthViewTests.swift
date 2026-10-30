import XCTest
import SwiftUI
import UIKit
import Foundation
@testable import KcalAnalysis

/// Synthetic data only. The rendering attachments are inspection evidence; data
/// invariants below are asserted independently of SwiftUI's rendering schedule.
@MainActor
final class NativeHealthViewTests: XCTestCase {
    func testMissingValuesStayDifferentFromExplicitZero() {
        XCTAssertNil(HealthUI.value(nil))
        XCTAssertNil(HealthUI.value(NSNull()))
        XCTAssertNil(HealthUI.value(true))
        XCTAssertNil(HealthUI.value(Double.nan))
        XCTAssertEqual(HealthUI.value(0), 0)
        XCTAssertEqual(HealthUI.input(nil), "")
        XCTAssertEqual(HealthUI.input(0), "0")
        XCTAssertEqual(HealthUI.number(nil), "—")
    }

    func testWeightPointsUseRealDatesAndRejectMetadataKeys() throws {
        let first = try XCTUnwrap(HealthWeightPoint(["k": "2024-01-01", "kg": 70.5]))
        let last = try XCTUnwrap(HealthWeightPoint(["k": "2024-01-22", "kg": 69.8]))
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day, 21)
        XCTAssertNil(HealthWeightPoint(["k": "2024-01-01|bf", "kg": 21]))
        XCTAssertNil(HealthWeightPoint(["k": "2024-02-30", "kg": 70]))
        XCTAssertNil(HealthWeightPoint(["k": "2024-01-02", "kg": NSNull()]))
        XCTAssertNil(HealthWeightPoint(["k": "2024-01-02", "kg": 0]))
    }

    func testLatestWeightExcludesFutureAndDoesNotTurnProfileIntoMeasurement() {
        let snapshot: [String: Any] = ["body": ["weightKg": 72], "weight": [
            "2024-01-01": 71.4, "2024-01-10": 71.1, "2024-12-01": 65,
            "2024-01-01|bf": 20
        ]]
        let profile = HealthUI.latestWeight(snapshot, through: "2023-12-31")
        XCTAssertNil(profile.0); XCTAssertEqual(profile.1, 72)
        let actual = HealthUI.latestWeight(snapshot, through: "2024-01-12")
        XCTAssertEqual(actual.0, "2024-01-10"); XCTAssertEqual(actual.1, 71.1)
    }

    func testEnergyPresentationPreservesOpenDayAndMissingFlags() {
        let zero = HealthEnergyDay(key: "2024-01-01", raw: ["intake": 0, "burn": 0,
            "hasIntake": true, "hasBurn": true, "closedDay": false, "source": "manual"])
        XCTAssertTrue(zero.hasIntake); XCTAssertTrue(zero.hasBurn)
        XCTAssertTrue(zero.measured); XCTAssertFalse(zero.closed)
        let missing = HealthEnergyDay(key: "2024-01-02", raw: ["intake": 0, "burn": 0,
            "hasIntake": false, "hasBurn": false, "closedDay": true, "source": "estimate"])
        XCTAssertFalse(missing.hasIntake); XCTAssertFalse(missing.hasBurn)
        XCTAssertFalse(missing.measured); XCTAssertTrue(missing.estimated)
    }

    func testSleepInputRequiresExplicitHourAndMinuteAndKeepsLocalWakeDate() throws {
        let day = try XCTUnwrap(HealthUI.date("2024-01-02"))
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 7, to: day))
        let start = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: -8, to: end))
        let input = try HealthUI.sleepInput(hours: "7", minutes: "0", includesTimes: true, start: start, end: end)
        XCTAssertEqual(HealthUI.value(input["asleepMinutes"]), 420)
        XCTAssertEqual((input["endAt"] as? String)?.prefix(10), "2024-01-02")
        XCTAssertEqual(HealthUI.instant(input["endAt"]), end)
        XCTAssertNil(input["stages"])
        let noTimes = try HealthUI.sleepInput(hours: "0", minutes: "0", includesTimes: false, start: start, end: end)
        XCTAssertEqual(HealthUI.value(noTimes["asleepMinutes"]), 0)
        XCTAssertNil(noTimes["startAt"]); XCTAssertNil(noTimes["endAt"])
        for invalid in [("", "0"), ("7", ""), ("7.5", "0"), ("7", "60"), ("24", "1")] {
            XCTAssertThrowsError(try HealthUI.sleepInput(hours: invalid.0, minutes: invalid.1,
                includesTimes: false, start: start, end: end))
        }
    }

    func testHealthQueriesDoNotWriteAndWeightWindowsDoNotFillMissingDays() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory), model = NativeAppModel(store: store)
        XCTAssertFalse(model.isReadOnly, model.error ?? "")
        XCTAssertNil(try store.load())
        _ = try model.query("energy", payload: ["date": "2024-01-30"])
        _ = try model.query("weightWindow", payload: ["mode": "all", "asOf": "2024-01-30", "anchor": "2024-01-30"])
        XCTAssertNil(try store.load(), "First browsing must not materialize an empty snapshot")
        try seed(model)
        let before = try store.load()
        for mode in ["all", "week", "month", "year"] {
            let window = try model.query("weightWindow", payload: ["mode": mode, "asOf": "2024-01-30", "anchor": "2024-01-30"])
            let records = try XCTUnwrap(window["records"] as? [[String: Any]])
            let points = records.compactMap(HealthWeightPoint.init)
            XCTAssertEqual(points.count, records.count)
            XCTAssertTrue(points.allSatisfy { ["2024-01-01", "2024-01-08", "2024-01-15", "2024-01-29"].contains($0.key) })
            if mode == "all" { XCTAssertEqual(points.count, 4) }
        }
        let energy = try model.query("energy", payload: ["date": "2024-01-29"])
        XCTAssertNotNil(energy["trend"] as? [String: Any])
        XCTAssertEqual(try store.load(), before, "Chart and statistics reads must not rewrite records")
    }

    func testInvalidSleepWakeDayLeavesExistingSnapshotUntouched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory), model = NativeAppModel(store: store)
        try seed(model)
        let before = try store.load()
        let end = try XCTUnwrap(HealthUI.date("2024-01-31"))
        let start = end.addingTimeInterval(-8 * 3_600)
        let input = try HealthUI.sleepInput(hours: "7", minutes: "0", includesTimes: true, start: start, end: end)
        XCTAssertThrowsError(try model.mutate("saveSleep", payload: ["date": "2024-01-30", "input": input]))
        XCTAssertEqual(try store.load(), before)
    }

    func testFiveHealthPagesRenderWithNarrowAndAccessibleNativeLayoutsWithoutWrites() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory), model = NativeAppModel(store: store)
        try seed(model)
        let before = try store.load()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        let variants: [(String, CGFloat, ColorScheme, DynamicTypeSize)] = [
            ("320-light", 320, .light, .large), ("393-dark-accessibility5", 393, .dark, .accessibility5)
        ]
        for variant in variants {
            let pages: [(String, AnyView)] = [
                ("overview", AnyView(HealthDashboard(model: model))),
                ("energy", AnyView(NativeEnergyDetail(model: model, onSync: {}, onImport: {}))),
                ("weight", AnyView(NativeWeightDetail(model: model))),
                ("training", AnyView(NativeTrainingDetail(model: model))),
                ("sleep", AnyView(NativeSleepDetail(model: model)))
            ]
            for page in pages {
                let view = NavigationStack { page.1 }
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .environment(\.colorScheme, variant.2)
                    .environment(\.dynamicTypeSize, variant.3)
                let host = UIHostingController(rootView: view)
                host.overrideUserInterfaceStyle = variant.2 == .dark ? .dark : .light
                // UIWindowScene owns the window size. Constrain a child host so
                // the test viewport remains exact on any simulator screen.
                let parent = UIViewController()
                parent.overrideUserInterfaceStyle = host.overrideUserInterfaceStyle
                window.frame = scene.coordinateSpace.bounds
                window.rootViewController = parent; window.makeKeyAndVisible()
                parent.addChild(host)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                parent.view.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.widthAnchor.constraint(equalToConstant: variant.1),
                    host.view.heightAnchor.constraint(equalToConstant: 844),
                    host.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
                    host.view.topAnchor.constraint(equalTo: parent.view.topAnchor)
                ])
                host.didMove(toParent: parent)
                parent.view.layoutIfNeeded()
                // Allow view tasks and a display pass to produce inspection images.
                // Correctness assertions do not depend on the timeout or pixels.
                for _ in 0..<4 { await Task.yield() }
                try await Task.sleep(nanoseconds: 150_000_000)
                host.view.layoutIfNeeded()
                XCTAssertEqual(host.view.bounds.width, variant.1, accuracy: 0.5,
                    "Inspection evidence must use its stated viewport width")
                XCTAssertEqual(host.view.bounds.height, 844, accuracy: 0.5)
                XCTAssertFalse(containsWebView(host.view), "Native health pages must not host HTML")
                XCTAssertGreaterThan(host.view.subviews.count, 0)
                var completedDrawing = false
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    completedDrawing = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                XCTAssertTrue(completedDrawing, "The attachment must contain a completed screen draw")
                let attachment = XCTAttachment(image: image)
                attachment.name = "swiftui-health-" + page.0 + "-" + variant.0
                attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertEqual(try store.load(), before, "Rendering \(page.0) must never persist data")
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kcal-native-health-" + UUID().uuidString, isDirectory: true)
    }

    private func seed(_ model: NativeAppModel) throws {
        XCTAssertFalse(model.isReadOnly, model.error ?? "")
        model.selectedDate = try XCTUnwrap(HealthUI.date("2024-01-29"))
        for (date, kg) in [("2024-01-01", 72.2), ("2024-01-08", 72.0), ("2024-01-15", 71.9), ("2024-01-29", 71.7)] {
            _ = try model.mutate("saveWeight", payload: ["date": date, "value": kg])
        }
        _ = try model.mutate("saveEnergy", payload: ["date": model.dayKey, "active": 450, "basal": 1500])
        _ = try model.mutate("saveTraining", payload: ["date": model.dayKey, "input": [
            "type": "步行", "durationMinutes": 35, "distanceKm": 2.6, "energyKcal": 100
        ]])
        _ = try model.mutate("saveSleep", payload: ["date": model.dayKey, "input": ["asleepMinutes": 435]])
    }

    private func containsWebView(_ view: UIView) -> Bool {
        String(describing: type(of: view)).contains("WKWebView") || view.subviews.contains(where: containsWebView)
    }
}
