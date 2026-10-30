import Foundation
import JavaScriptCore

protocol NativeSnapshotStoring {
    func load() throws -> String?
    func save(raw: String, expectedRaw: String?) throws
}

extension SnapshotStore: NativeSnapshotStoring {}

/// Swift owns the authoritative snapshot and commits. JavaScriptCore runs only the
/// reviewed pure calculations extracted from the PWA; it has no web view or I/O.
@MainActor
final class NativeDomain {
    // The invocation contains both the current snapshot and an import candidate.
    // Its envelope may therefore exceed the 32 MB authoritative snapshot limit.
    // Allow one full compact snapshot plus a full compact backup, whose JSON text
    // may double in size when escaped inside the command, and a small envelope.
    // A 96 MB file accepted by the file picker is still subject to this combined
    // transfer limit. SnapshotStore independently keeps saved snapshots at 32 MB.
    static let maximumRequestBytes = SnapshotStore.maximumBytes * 3 + 4096
    private let store: NativeSnapshotStoring
    private let context: JSContext
    private let execute: JSValue
    private var persistedRaw: String?
    private var originalReadFailure = false
    private(set) var snapshot: [String: Any] = [:]
    private(set) var storageIssue: String?
    var readOnly: Bool { storageIssue != nil }

    init(store: NativeSnapshotStoring = SnapshotStore(), bundle: Bundle = .main, engineURL: URL? = nil) throws {
        self.store = store
        guard let context = JSContext() else { throw NativeFailure("domain_unavailable", "无法启动本地计算引擎") }
        self.context = context
        let sourceURL = engineURL ?? bundle.url(forResource: "domain", withExtension: "js", subdirectory: "domain")
            ?? bundle.url(forResource: "domain", withExtension: "js")
        guard let sourceURL else { throw NativeFailure("domain_missing", "安装包缺少本地计算引擎，请重新安装完整版本") }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: sourceURL)
        if let exception = context.exception {
            throw NativeFailure("domain_invalid", "本地计算引擎无法加载：" + (exception.toString() ?? "未知错误"))
        }
        guard let engine = context.objectForKeyedSubscript("NativeDomainEngine"),
              !engine.isUndefined, let execute = engine.objectForKeyedSubscript("execute"), !execute.isUndefined else {
            throw NativeFailure("domain_invalid", "本地计算引擎接口缺失")
        }
        self.execute = execute
        // Even a corrupt/unreadable file must leave the app usable for recovery.
        // Initialization never writes, migrates or replaces a snapshot on disk.
        let empty = try invoke("initialize", payload: [:], source: NSNull(), mutation: false)
        snapshot = empty["snapshot"] as? [String: Any] ?? [:]
        do {
            persistedRaw = try store.load()
            if let raw = persistedRaw {
                guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw NativeFailure("storage_invalid", "本地快照必须是完整记录对象，已停止覆盖")
                }
                let loaded = try invoke("initialize", payload: [:], source: value, mutation: false)
                guard let data = loaded["snapshot"] as? [String: Any] else {
                    throw NativeFailure("storage_invalid", "本地快照无法读取")
                }
                snapshot = data
            }
        } catch {
            originalReadFailure = true
            storageIssue = "本地记录读取异常，已暂停写入。" + error.localizedDescription
        }
    }

    func query(_ operation: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        if operation == "exportBackup" {
            if originalReadFailure {
                // Preserve the actual original bytes as a JSON string, including malformed JSON.
                // If the file is temporarily unreadable, fail visibly instead of exporting an empty backup.
                let raw = try store.load()
                let recovery: [String: Any] = ["app": "kcal-recovery", "exportedAt": ISO8601DateFormatter().string(from: Date()),
                                               "raw": ["kcal.data.v5": raw as Any? ?? NSNull()]]
                let data = try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted, .sortedKeys])
                return ["text": String(decoding: data, as: UTF8.self), "recovery": true]
            }
            try verifyCurrentSnapshot()
        }
        return try invoke(operation, payload: payload, source: snapshot, mutation: false)
    }

    @discardableResult
    func mutate(_ operation: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        var arguments = payload
        if readOnly {
            guard originalReadFailure, operation == "restore" else {
                throw NativeFailure("storage_read_only", storageIssue ?? "请重新打开 App 后再保存")
            }
            arguments["recovering"] = true
        }
        // Recompute against the current snapshot at confirmation time. The preview
        // is never itself a prepared write or an authority to overwrite later data.
        let result = try invoke(operation, payload: arguments, source: snapshot, mutation: true)
        guard let next = result["snapshot"] as? [String: Any] else {
            throw NativeFailure("domain_invalid", "保存结果缺少完整快照")
        }
        try verifyCurrentSnapshot()
        if (result["changed"] as? Bool) == false && !originalReadFailure { return result }
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        let raw = String(decoding: data, as: UTF8.self)
        do {
            try store.save(raw: raw, expectedRaw: persistedRaw)
        } catch let error as NativeFailure {
            if error.code == "storage_conflict" { storageIssue = error.message }
            throw error
        }
        // Publish only after the atomic file write succeeds. Failure leaves the
        // exact old in-memory state and the original authoritative file intact.
        persistedRaw = raw
        snapshot = next
        storageIssue = nil
        originalReadFailure = false
        return result
    }

    private func verifyCurrentSnapshot() throws {
        guard try store.load() == persistedRaw else {
            let issue = NativeFailure("storage_conflict", "记录已被其他操作更新，请重新打开 App 后再保存或导出。")
            storageIssue = issue.message
            throw issue
        }
    }

    private func invoke(_ operation: String, payload: [String: Any], source: Any, mutation: Bool) throws -> [String: Any] {
        let request: [String: Any] = ["operation": operation, "payload": payload, "snapshot": source, "mutation": mutation]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw NativeFailure("domain_input", "输入包含无效的数值或格式")
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= Self.maximumRequestBytes else {
            throw NativeFailure("domain_too_large", "导入内容与现有记录合计超过传输限制（约 96 MB），请压缩 JSON 中的空白或缩小导入范围。原记录没有改变。")
        }
        context.exception = nil
        guard let text = execute.call(withArguments: [String(decoding: data, as: UTF8.self)])?.toString(),
              context.exception == nil, let response = text.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw NativeFailure("domain_failed", "本地计算未完成，记录没有改变")
        }
        guard envelope["ok"] as? Bool == true, let result = envelope["value"] as? [String: Any] else {
            throw NativeFailure("domain_validation", envelope["error"] as? String ?? "输入无效")
        }
        return result
    }
}
