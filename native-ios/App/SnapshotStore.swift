import Foundation

/// The native file is authoritative. WebKit's cache and website data are not backups.
final class SnapshotStore {
    static let maximumBytes = 32 * 1024 * 1024
    private let fileManager = FileManager.default
    private let directory: URL
    private let file: URL
    private let lock = NSLock()

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KcalAnalysis", isDirectory: true)
        file = directory.appendingPathComponent("snapshot.json", isDirectory: false)
    }

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try readUnlocked()
    }

    /// Compare-and-swap preserves the web app's existing conflict and rollback contract.
    func save(raw: String, expectedRaw: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard try readUnlocked() == expectedRaw else {
            throw NativeFailure("storage_conflict", "数据已在其他操作中更新，请重新打开页面后再保存。")
        }
        let data = Data(raw.utf8)
        guard data.count <= Self.maximumBytes else {
            throw NativeFailure("storage_too_large", "记录超过本地快照大小限制，请先导出完整备份。")
        }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw NativeFailure("storage_invalid_json", "快照必须是完整 JSON 对象，未写入文件。")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // .atomic writes a sibling file then replaces; failed writes retain the last snapshot.
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readUnlocked() throws -> String? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: file.path) }
        catch {
            let issue = error as NSError
            // Do not treat permissions, protected data or I/O failures as an empty first launch.
            if issue.domain == NSCocoaErrorDomain,
               issue.code == NSFileReadNoSuchFileError || issue.code == NSFileNoSuchFileError { return nil }
            throw error
        }
        if let bytes = attributes[.size] as? NSNumber, bytes.intValue > Self.maximumBytes {
            throw NativeFailure("storage_too_large", "本地快照过大，已停止读取和覆盖。")
        }
        let data = try Data(contentsOf: file)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw NativeFailure("storage_invalid_encoding", "本地快照无法按 UTF-8 读取，已停止覆盖。")
        }
        return raw
    }
}

struct NativeFailure: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
