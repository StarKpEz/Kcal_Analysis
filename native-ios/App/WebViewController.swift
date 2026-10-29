import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let store = SnapshotStore()
    private var webView: WKWebView!
    private var bridge: NativeBridge!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        bridge = NativeBridge(presenter: self, store: store)
        let content = WKUserContentController()
        content.add(bridge, name: "kcalNative")
        content.addUserScript(WKUserScript(source: bootstrap(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .default()
        configuration.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "kcalapp")
        webView = WKWebView(frame: .zero, configuration: configuration)
        bridge.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.load(URLRequest(url: URL(string: "kcalapp://localhost/index.html")!))
    }

    private func bootstrap() -> String {
        var snapshot: Any = NSNull()
        var failure: Any = NSNull()
        do { snapshot = try store.load() as Any? ?? NSNull() }
        catch { failure = error.localizedDescription }
        return "window.__KCAL_NATIVE__ = true; window.__KCAL_NATIVE_SNAPSHOT__ = \(NativeBridge.json(snapshot)); window.__KCAL_NATIVE_STORAGE_ERROR__ = \(NativeBridge.json(failure));"
    }

    func notifyResume() {
        guard isViewLoaded, NativeBridge.isAppDocument(webView.url) else { return }
        webView.evaluateJavaScript("if (window.KcalNative && typeof window.KcalNative.onResume === 'function') window.KcalNative.onResume();", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if NativeBridge.isLocal(url) {
            // Embedded frames have no native capability; all application navigation stays local.
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false {
            bridge.openExternal(url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if NativeBridge.isLocal(url) { webView.load(URLRequest(url: url)) }
            else { bridge.openExternal(url) }
        }
        return nil
    }

    private func trusted(_ frame: WKFrameInfo) -> Bool {
        frame.isMainFrame && NativeBridge.isAppDocument(frame.request.url) && NativeBridge.isAppDocument(webView.url)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard trusted(frame) else { completionHandler(nil); return }
        if prompt == "__KCAL_STORAGE__" {
            // Intentionally synchronous: commitData must see disk errors before reporting success.
            completionHandler(bridge.synchronousStorage(defaultText))
            return
        }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak alert] _ in
            Self.finishDialog(alert) { completionHandler(nil) }
        })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            Self.finishDialog(alert) { completionHandler(value) }
        })
        presentDialog(alert, fallback: { completionHandler(nil) })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard trusted(frame) else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak alert] _ in
            Self.finishDialog(alert) { completionHandler(false) }
        })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            Self.finishDialog(alert) { completionHandler(true) }
        })
        presentDialog(alert, fallback: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard trusted(frame) else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak alert] _ in
            Self.finishDialog(alert, completion: completionHandler)
        })
        presentDialog(alert, fallback: completionHandler)
    }

    private func presentDialog(_ alert: UIAlertController, fallback: () -> Void) {
        guard presentedViewController == nil, viewIfLoaded?.window != nil else { fallback(); return }
        present(alert, animated: true)
    }

    private static func finishDialog(_ alert: UIAlertController?, completion: @escaping () -> Void) {
        guard let alert, alert.presentingViewController != nil else { completion(); return }
        // Manual food entry uses consecutive prompts. Return to JS after dismissal so the
        // next prompt does not collide with the previous alert's presentation transition.
        alert.dismiss(animated: true, completion: completion)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A process restart re-reads the authoritative snapshot through the synchronous bridge.
        webView.reload()
    }
}

private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, NativeBridge.isLocal(url),
              urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET",
              let resources = Bundle.main.resourceURL else {
            urlSchemeTask.didFailWithError(NativeFailure("invalid_resource", "不允许访问此资源。")); return
        }
        let root = resources.appendingPathComponent("Web", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let relative = url.path == "/" || url.path.isEmpty ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            urlSchemeTask.didFailWithError(NativeFailure("invalid_resource", "资源路径超出应用范围。")); return
        }
        do {
            let data = try Data(contentsOf: file)
            let types = ["html": "text/html", "css": "text/css", "js": "application/javascript", "json": "application/json", "webmanifest": "application/manifest+json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "woff2": "font/woff2"]
            let mime = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
            let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") ? "utf-8" : nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Delivery is synchronous; there is no outstanding network work to cancel.
    }
}
