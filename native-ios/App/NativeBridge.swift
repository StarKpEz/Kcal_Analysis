import UIKit
import WebKit
import UniformTypeIdentifiers

final class NativeBridge: NSObject, WKScriptMessageHandler, UIDocumentPickerDelegate {
    weak var webView: WKWebView?
    private weak var presenter: UIViewController?
    private let store: SnapshotStore
    private let health = HealthKitService()
    private var pendingPicker: ((Result<[String: Any], Error>) -> Void)?
    private let preferencePrefix = "kcal.native."
    // Transport must fit every valid compact snapshot, formatted legacy backups
    // and the escaped raw snapshot inside a recovery export.
    private static let maximumTransferBytes = SnapshotStore.maximumBytes * 3

    init(presenter: UIViewController, store: SnapshotStore) {
        self.presenter = presenter
        self.store = store
    }

    static func isLocal(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "kcalapp" && url.host?.lowercased() == "localhost"
            && url.port == nil && url.user == nil && url.password == nil
    }

    static func isAppDocument(_ url: URL?) -> Bool {
        isLocal(url) && (url?.path == "/index.html" || url?.path == "/" || url?.path == "")
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// Only WebViewController's trusted, main-frame prompt path may enter this method.
    func synchronousStorage(_ payload: String?) -> String {
        do {
            // Both raw snapshots are nested JSON strings; allow their escaping overhead.
            guard let payload, let data = payload.data(using: .utf8), data.count <= SnapshotStore.maximumBytes * 4 + 4096,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let operation = body["operation"] as? String else {
                throw NativeFailure("invalid_request", "无效的本地存储请求。")
            }
            if operation == "read" {
                return Self.json(["ok": true, "raw": try store.load() as Any? ?? NSNull()])
            }
            if operation == "write" {
                let values = try storageWriteValues(body)
                try store.save(raw: values.raw, expectedRaw: values.expected)
                return Self.json(["ok": true])
            }
            throw NativeFailure("unknown_operation", "不支持的本地存储操作。")
        } catch { return Self.json(errorBody(error, includeOK: true)) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "kcalNative", message.frameInfo.isMainFrame,
              Self.isAppDocument(message.frameInfo.request.url), Self.isAppDocument(webView?.url),
              message.frameInfo.securityOrigin.protocol == "kcalapp", message.frameInfo.securityOrigin.host == "localhost",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String, !id.isEmpty, id.count <= 100,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        let complete: (Result<[String: Any], Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async { self?.reply(id: id, result: result) }
        }
        do {
            switch method {
            case "storage.load":
                complete(.success(["raw": try store.load() as Any? ?? NSNull()]))
            case "storage.save":
                let values = try storageWriteValues(params)
                try store.save(raw: values.raw, expectedRaw: values.expected)
                complete(.success(["saved": true]))
            case "preferences.load": complete(.success(preferences()))
            case "preferences.save": complete(.success(try savePreferences(params)))
            case "file.pick": try pickFile(complete)
            case "share.text": try share(params, complete: complete)
            case "clipboard.read": complete(.success(["text": UIPasteboard.general.string ?? ""]))
            case "clipboard.write":
                guard let text = params["text"] as? String, text.utf8.count <= SnapshotStore.maximumBytes else {
                    throw NativeFailure("invalid_text", "剪贴板文本无效或过大。")
                }
                UIPasteboard.general.string = text
                complete(.success(["written": true]))
            case "external.open":
                guard let value = params["url"] as? String, value.count <= 8192, let url = URL(string: value) else {
                    throw NativeFailure("invalid_url", "链接格式无效。")
                }
                openExternal(url) { opened in
                    if opened { complete(.success(["opened": true])) }
                    else { complete(.failure(NativeFailure("cannot_open", "无法打开此链接，请检查对应 App 是否安装。"))) }
                }
            case "health.authorize": health.authorize(completion: complete)
            case "health.sync": health.sync(params: params, completion: complete)
            default: throw NativeFailure("unknown_method", "不支持的原生操作。")
            }
        } catch { complete(.failure(error)) }
    }

    private func storageWriteValues(_ params: [String: Any]) throws -> (raw: String, expected: String?) {
        guard let raw = params["raw"] as? String, params.keys.contains("expectedRaw"),
              params["expectedRaw"] is String || params["expectedRaw"] is NSNull else {
            throw NativeFailure("invalid_storage_write", "保存须包含完整快照和上次读取值。")
        }
        return (raw, params["expectedRaw"] as? String)
    }

    private func preferences() -> [String: Any] {
        let defaults = UserDefaults.standard
        return ["autoSync": defaults.bool(forKey: preferencePrefix + "autoSync"),
                "sleepSource": defaults.string(forKey: preferencePrefix + "sleepSource") as Any? ?? NSNull()]
    }

    private func savePreferences(_ params: [String: Any]) throws -> [String: Any] {
        // Validate every value before writing any preference.
        if let auto = params["autoSync"], !(auto is Bool) { throw NativeFailure("invalid_preference", "自动同步设置须为布尔值。") }
        if let source = params["sleepSource"], !(source is NSNull), !(source is String) {
            throw NativeFailure("invalid_preference", "睡眠来源设置无效。")
        }
        if let source = params["sleepSource"] as? String, source.count > 512 { throw NativeFailure("invalid_preference", "睡眠来源设置过长。") }
        let defaults = UserDefaults.standard
        if let auto = params["autoSync"] as? Bool { defaults.set(auto, forKey: preferencePrefix + "autoSync") }
        if params["sleepSource"] is NSNull { defaults.removeObject(forKey: preferencePrefix + "sleepSource") }
        else if let source = params["sleepSource"] as? String { defaults.set(source, forKey: preferencePrefix + "sleepSource") }
        return preferences()
    }

    private func reply(id: String, result: Result<[String: Any], Error>) {
        guard Self.isAppDocument(webView?.url) else { return }
        var message: [String: Any] = ["id": id]
        switch result {
        case .success(let value): message["result"] = value
        case .failure(let error): message["error"] = errorBody(error)
        }
        webView?.evaluateJavaScript("if (window.KcalNative && typeof window.KcalNative.receive === 'function') window.KcalNative.receive(\(Self.json(message)));", completionHandler: nil)
    }

    private func errorBody(_ error: Error, includeOK: Bool = false) -> [String: Any] {
        let failure = error as? NativeFailure
        var result: [String: Any] = ["code": failure?.code ?? "native_failed", "message": failure?.message ?? error.localizedDescription]
        if includeOK { result["ok"] = false }
        return result
    }

    private func pickFile(_ complete: @escaping (Result<[String: Any], Error>) -> Void) throws {
        guard pendingPicker == nil, let presenter, presenter.presentedViewController == nil else {
            throw NativeFailure("busy", "请先关闭当前文件或分享窗口。")
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        pendingPicker = complete
        presenter.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let callback = pendingPicker
        pendingPicker = nil
        callback?(.success(["cancelled": true]))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let callback = pendingPicker
        pendingPicker = nil
        do {
            guard let url = urls.first else { throw NativeFailure("no_file", "未选择文件。") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumTransferBytes else { throw NativeFailure("file_too_large", "文件超过 96 MB，请核对是否为完整备份。") }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maximumTransferBytes, let text = String(data: data, encoding: .utf8) else {
                throw NativeFailure("invalid_file", "请选择不超过 96 MB 的 UTF-8 JSON 文件。")
            }
            callback?(.success(["name": url.lastPathComponent, "text": text, "cancelled": false]))
        } catch { callback?(.failure(error)) }
    }

    private func share(_ params: [String: Any], complete: @escaping (Result<[String: Any], Error>) -> Void) throws {
        guard let presenter, presenter.presentedViewController == nil else { throw NativeFailure("busy", "请先关闭当前窗口。") }
        guard let text = params["text"] as? String, text.utf8.count <= Self.maximumTransferBytes else {
            throw NativeFailure("invalid_text", "分享内容无效或过大。")
        }
        var temporaryDirectory: URL?
        let item: Any
        if let filename = params["filename"] as? String {
            let name = (filename as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", name.count <= 200 else { throw NativeFailure("invalid_filename", "文件名无效。") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KcalExport-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name, isDirectory: false)
            do { try Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            temporaryDirectory = directory
            item = file
        } else { item = text }
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activity.completionWithItemsHandler = { activityType, completed, _, error in
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            if let error { complete(.failure(error)) }
            else { complete(.success(["completed": completed, "activityType": activityType?.rawValue as Any? ?? NSNull()])) }
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    func openExternal(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        let denied = ["file", "javascript", "data", "kcalapp", "blob", "about", "applewebdata"]
        guard let scheme = url.scheme?.lowercased(), !denied.contains(scheme), !scheme.isEmpty,
              url.user == nil, url.password == nil else { completion?(false); return }
        if scheme == "https" || scheme == "http" {
            guard let host = url.host, !host.isEmpty else { completion?(false); return }
        }
        UIApplication.shared.open(url, options: [:]) { completion?($0) }
    }
}
