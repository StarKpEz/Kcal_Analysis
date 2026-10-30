import XCTest
@testable import KcalAnalysis

/// Runs the shipped domain in Apple's real JavaScriptCore. Data is synthetic and
/// all actual file writes are limited to an isolated temporary test directory.
final class NativeDomainTests: XCTestCase {
    private let day = "2026-10-05"
    private let food: [String: Any] = ["name": "虚构米饭", "grams": 200, "kcal": 232,
                                       "protein": 5, "fat": 0.6, "carbs": 51]

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeDomainTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func itemPayload() -> [String: Any] {
        ["date": day, "meal": "lunch", "items": [food]]
    }

    @MainActor
    func testEmptyInitializationAndReadOnlyQueriesNeverCreateSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let domain = try NativeDomain(store: store)
        XCTAssertFalse(domain.readOnly)
        XCTAssertEqual((domain.snapshot["version"] as? NSNumber)?.intValue, 7)
        _ = try domain.query("summary", payload: ["date": day])
        _ = try domain.query("parseFood", payload: ["text": "虚构米饭 | 200g | 232kcal | 蛋白质5g | 脂肪0.6g | 碳水51g"])
        _ = try domain.query("energy", payload: ["date": day])
        _ = try domain.query("weightWindow", payload: ["mode": "month", "anchor": day, "asOf": day])
        _ = try domain.query("exportBackup")
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testFoodMutationPersistsAndReloadsThroughRealAtomicStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let domain = try NativeDomain(store: store)
        try domain.mutate("addFood", payload: itemPayload())
        try domain.mutate("scaleFood", payload: ["date": day, "meal": "lunch", "index": 0, "grams": 100])
        let raw = try XCTUnwrap(store.load())
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(try canonical(persisted), try canonical(domain.snapshot))
        let reloaded = try NativeDomain(store: store)
        XCTAssertEqual(try canonical(reloaded.snapshot), try canonical(domain.snapshot))
        let summary = try reloaded.query("summary", payload: ["date": day])
        let totals = try XCTUnwrap(summary["totals"] as? [String: Any])
        XCTAssertEqual((totals["kcal"] as? NSNumber)?.doubleValue, 116)
        XCTAssertEqual((totals["c"] as? NSNumber)?.doubleValue, 25.5)
    }

    @MainActor
    func testInvalidMutationLeavesMemoryAndOriginalBytesUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let domain = try NativeDomain(store: store)
        try domain.mutate("addFood", payload: itemPayload())
        let before = try canonical(domain.snapshot), raw = try store.load()
        XCTAssertThrowsError(try domain.mutate("editFood", payload: ["date": day, "meal": "lunch", "index": 0, "item": ["kcal": -1]]))
        XCTAssertThrowsError(try domain.mutate("saveWeight", payload: ["date": "2026-02-30", "value": 70]))
        XCTAssertThrowsError(try domain.mutate("saveEnergy", payload: ["date": day, "active": 400]))
        XCTAssertEqual(try canonical(domain.snapshot), before)
        XCTAssertEqual(try store.load(), raw)
    }

    @MainActor
    func testSecondOwnerCannotOverwriteOrExportStaleSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let first = try NativeDomain(store: store), stale = try NativeDomain(store: store)
        let before = try canonical(stale.snapshot)
        try first.mutate("addFood", payload: itemPayload())
        let raw = try store.load()
        XCTAssertThrowsError(try stale.mutate("saveWeight", payload: ["date": day, "value": 70])) { error in
            XCTAssertEqual((error as? NativeFailure)?.code, "storage_conflict")
        }
        XCTAssertTrue(stale.readOnly)
        XCTAssertThrowsError(try stale.query("exportBackup"))
        XCTAssertEqual(try canonical(stale.snapshot), before)
        XCTAssertEqual(try store.load(), raw)
    }

    @MainActor
    func testCorruptSnapshotExportsOriginalBytesAndOnlyFullReplaceCanRecover() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let broken = "{\"app\":\"kcal\",\"entries\": [ interrupted"
        try Data(broken.utf8).write(to: file)
        let store = SnapshotStore(directory: directory)
        let domain = try NativeDomain(store: store)
        XCTAssertTrue(domain.readOnly)
        XCTAssertThrowsError(try domain.mutate("addFood", payload: itemPayload()))
        let backup = try domain.query("exportBackup")
        XCTAssertEqual(backup["recovery"] as? Bool, true)
        let text = try XCTUnwrap(backup["text"] as? String)
        let recovery = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((recovery["raw"] as? [String: Any])?["kcal.data.v5"] as? String, broken)
        XCTAssertThrowsError(try domain.mutate("restore", payload: ["text": "{\"entries\":{}}", "mode": "replace"]))
        let valid = String(decoding: try canonical(domain.snapshot), as: UTF8.self)
        XCTAssertThrowsError(try domain.mutate("restore", payload: ["text": valid, "mode": "merge"]))
        XCTAssertEqual(try store.load(), broken)
        try domain.mutate("restore", payload: ["text": valid, "mode": "replace"])
        XCTAssertFalse(domain.readOnly)
        XCTAssertNil(domain.storageIssue)
        XCTAssertNotEqual(try store.load(), broken)
        XCTAssertFalse(try NativeDomain(store: store).readOnly)
    }

    @MainActor
    func testNullAndIncompleteSnapshotsAreProtectedInsteadOfTreatedAsEmptyLaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        for raw in ["null", "[]", "{}", "{\"app\":\"kcal\",\"version\":7}"] {
            try Data(raw.utf8).write(to: file, options: .atomic)
            let store = SnapshotStore(directory: directory)
            let domain = try NativeDomain(store: store)
            XCTAssertTrue(domain.readOnly, raw)
            XCTAssertThrowsError(try domain.mutate("addFood", payload: itemPayload()))
            XCTAssertEqual(try store.load(), raw)
        }
    }

    @MainActor
    func testHealthPreviewDoesNotWriteAndEmptyReadNeverClearsExistingEnergy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let domain = try NativeDomain(store: store)
        try domain.mutate("saveEnergy", payload: ["date": day, "active": 600, "basal": 1400])
        let raw = try store.load()
        let payload: [String: Any] = ["nativeResult": ["daily": NSNull(), "sleepSamples": NSNull(), "notes": ["虚构空查询"]], "from": day, "through": day]
        let preview = try domain.query("previewHealth", payload: payload)
        XCTAssertEqual((preview["updates"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(try store.load(), raw)
        let result = try domain.mutate("importHealth", payload: payload)
        XCTAssertEqual(result["changed"] as? Bool, false)
        XCTAssertEqual(try store.load(), raw)
        let energy = try domain.query("energy", payload: ["date": day])
        XCTAssertEqual((energy["burn"] as? NSNumber)?.doubleValue, 2000)
    }

    @MainActor
    func testStaleFoodEditorCannotChangeAnotherItemAtTheSameIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory), app = try NativeDomain(store: SnapshotStore(directory: directory))
        var second = food
        second["name"] = "虚构第二项"
        try app.mutate("addFood", payload: ["date": day, "meal": "lunch", "items": [food, second]])
        try app.mutate("deleteFood", payload: ["date": day, "meal": "lunch", "index": 0, "expectedItem": food])
        let raw = try store.load()
        for operation in ["editFood", "deleteFood", "moveFood", "scaleFood"] {
            XCTAssertThrowsError(try app.mutate(operation, payload: ["date": day, "meal": "lunch", "index": 0,
                "expectedItem": food, "item": ["kcal": 999], "grams": 100, "toMeal": "dinner"]))
        }
        XCTAssertEqual(try store.load(), raw)
    }

    @MainActor
    func testLargeValidEditCanCarrySnapshotAndExpectedItemWithoutRelaxingFileLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let app = try NativeDomain(store: store)
        var large = food
        // Synthetic metadata tests the actual transfer boundary without millions
        // of rows or any real records. One item fits; two exceed the saved-file cap.
        large["annotation"] = String(repeating: "x", count: SnapshotStore.maximumBytes / 2)
        try app.mutate("addFood", payload: ["date": day, "meal": "lunch", "items": [large]])
        try app.mutate("editFood", payload: ["date": day, "meal": "lunch", "index": 0,
            "expectedItem": large, "item": ["kcal": 233]])
        let raw = try XCTUnwrap(store.load())
        XCTAssertLessThan(raw.utf8.count, SnapshotStore.maximumBytes)
        XCTAssertThrowsError(try app.mutate("addFood", payload: ["date": day, "meal": "lunch", "items": [large]])) { error in
            XCTAssertEqual((error as? NativeFailure)?.code, "storage_too_large")
        }
        XCTAssertEqual(try store.load(), raw)
        let summary = try app.query("summary", payload: ["date": day])
        XCTAssertEqual(((summary["totals"] as? [String: Any])?["kcal"] as? NSNumber)?.intValue, 233)
    }

    /// The production writer remains SnapshotStore; this seam injects only the
    /// failure boundary that cannot be reliably forced using simulator permissions.
    private final class FailingStore: NativeSnapshotStoring {
        var raw: String?
        var failWrite = false
        var raceAtWrite = false
        var writes = 0
        func load() throws -> String? { raw }
        func save(raw next: String, expectedRaw: String?) throws {
            writes += 1
            if raceAtWrite { raw = "{\"external\":true}" }
            guard raw == expectedRaw else { throw NativeFailure("storage_conflict", "模拟并发变更") }
            if failWrite { throw NativeFailure("storage_write_failed", "模拟磁盘写入失败") }
            raw = next
        }
    }

    @MainActor
    func testWriteFailureDoesNotPublishCandidateAndCanBeRetried() throws {
        let store = FailingStore()
        let app = try NativeDomain(store: store)
        try app.mutate("addFood", payload: itemPayload())
        let raw = store.raw, before = try canonical(app.snapshot)
        store.failWrite = true
        XCTAssertThrowsError(try app.mutate("saveWeight", payload: ["date": day, "value": 70]))
        XCTAssertEqual(store.raw, raw)
        XCTAssertEqual(try canonical(app.snapshot), before)
        store.failWrite = false
        try app.mutate("saveWeight", payload: ["date": day, "value": 70])
        XCTAssertEqual(((app.snapshot["weight"] as? [String: Any])?[day] as? NSNumber)?.doubleValue, 70)
        XCTAssertEqual(store.writes, 3)
    }

    @MainActor
    func testCASAtWriteCatchesRaceAfterPreflightRead() throws {
        let store = FailingStore()
        let app = try NativeDomain(store: store)
        let before = try canonical(app.snapshot)
        store.raceAtWrite = true
        XCTAssertThrowsError(try app.mutate("addFood", payload: itemPayload())) { error in
            XCTAssertEqual((error as? NativeFailure)?.code, "storage_conflict")
        }
        XCTAssertTrue(app.readOnly)
        XCTAssertEqual(try canonical(app.snapshot), before)
        XCTAssertEqual(store.raw, "{\"external\":true}")
    }
}
