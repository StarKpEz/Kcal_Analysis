import UIKit
import WebKit
import SwiftUI

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let store: SnapshotStore
    private let health: NativeHealthProviding
    private let launcher: ExternalAppLauncher
    private(set) var webView: WKWebView!
    private(set) var bridge: NativeBridge!
    private let tabBarState = NativeTabBarState()
    private var tabHost: UIHostingController<NativeTabBar>?
    private var tabWidth: NSLayoutConstraint?
    private var hasNavigationState = false
    private var nativeNavigationDisabled = false
    private var requestedNavigationVisible = false
    private var pageIsLoading = true
    private var keyboardVisible = false
    private var navigationGeneration = 0
    private var lastClearance: CGFloat?

    init(store: SnapshotStore = SnapshotStore(), health: NativeHealthProviding = HealthKitService(),
         launcher: ExternalAppLauncher = ExternalAppLauncher()) {
        self.store = store
        self.health = health
        self.launcher = launcher
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        store = SnapshotStore()
        health = HealthKitService()
        launcher = ExternalAppLauncher()
        super.init(coder: coder)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        bridge = NativeBridge(presenter: self, store: store, health: health, launcher: launcher)
        bridge.onNavigationState = { [weak self] section, visible in
            self?.receiveNavigationState(section: section, visible: visible)
        }
        bridge.onNavigationDisabled = { [weak self] in self?.disableNativeNavigation() }
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
        installNativeNavigation()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.load(URLRequest(url: URL(string: "kcalapp://localhost/index.html")!))
    }

    private func installNativeNavigation() {
        tabBarState.onSelect = { [weak self] section in self?.selectNativeSection(section) }
        let host = UIHostingController(rootView: NativeTabBar(state: tabBarState))
        host.sizingOptions = [.intrinsicContentSize]
        // UIKit applies the screen safe area once, in the bottom constraint below.
        host.safeAreaRegions = []
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.isHidden = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(host.view)
        let width = host.view.widthAnchor.constraint(equalToConstant: navigationWidth)
        NSLayoutConstraint.activate([
            width,
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        host.didMove(toParent: self)
        tabHost = host
        tabWidth = width
    }

    private var navigationWidth: CGFloat { max(0, min(288, view.bounds.width - 32)) }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let width = tabWidth, abs(width.constant - navigationWidth) > 0.5 {
            width.constant = navigationWidth
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateInsets(force: true)
    }

    private func receiveNavigationState(section: String, visible: Bool) {
        guard !nativeNavigationDisabled, isViewLoaded, NativeBridge.isAppDocument(webView?.url), ["diet", "health"].contains(section) else { return }
        tabBarState.section = section
        hasNavigationState = true
        requestedNavigationVisible = visible
        updateNavigationVisibility()
        updateInsets(force: true)
    }

    private func updateNavigationVisibility() {
        let visible = hasNavigationState && requestedNavigationVisible && !pageIsLoading && !keyboardVisible
            && NativeBridge.isAppDocument(webView?.url)
        if tabBarState.visible != visible { tabBarState.visible = visible }
        tabHost?.view.isHidden = !visible
    }

    private func resetNativeNavigation() {
        navigationGeneration += 1
        nativeNavigationDisabled = false
        hasNavigationState = false
        requestedNavigationVisible = false
        lastClearance = nil
        updateNavigationVisibility()
    }

    private func selectNativeSection(_ section: String) {
        guard tabBarState.visible, ["diet", "health"].contains(section),
              NativeBridge.isAppDocument(webView.url) else { return }
        let generation = navigationGeneration
        // JS clicks the existing navigation link, retaining route memory and import guards.
        webView.evaluateJavaScript("window.KcalNativeNavigation?.select(\(NativeBridge.json(section)));") { [weak self] result, error in
            guard let self, self.navigationGeneration == generation, !self.pageIsLoading,
                  NativeBridge.isAppDocument(self.webView.url) else { return }
            // false is a normal refusal while a modal/visibility transition is pending.
            if error != nil || !(result is Bool) {
                self.disableNativeNavigation()
                // Restore the HTML navigation if the new JS adapter is unavailable or fails.
                self.restoreWebNavigation()
            }
        }
    }

    private func disableNativeNavigation() {
        nativeNavigationDisabled = true
        hasNavigationState = false
        requestedNavigationVisible = false
        updateNavigationVisibility()
    }

    private func restoreWebNavigation() {
        guard isViewLoaded, NativeBridge.isAppDocument(webView?.url) else { return }
        webView.evaluateJavaScript("window.KcalNativeNavigation?.setEnabled(false);", completionHandler: nil)
    }

    private func updateInsets(force: Bool = false) {
        guard isViewLoaded, !pageIsLoading, let host = tabHost,
              NativeBridge.isAppDocument(webView?.url), host.view.bounds.height > 0 else { return }
        let clearance = ceil(host.view.bounds.height + view.safeAreaInsets.bottom + 24)
        if !force, let previous = lastClearance, abs(previous - clearance) < 0.5 { return }
        lastClearance = clearance
        webView.evaluateJavaScript("window.KcalNativeNavigation?.setClearance(\(Int(clearance)));", completionHandler: nil)
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let localFrame = view.convert(frame, from: nil)
        keyboardVisible = !view.bounds.intersection(localFrame).isEmpty
        updateNavigationVisibility()
    }

    @objc private func keyboardHidden(_ notification: Notification) {
        keyboardVisible = false
        updateNavigationVisibility()
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageIsLoading = true
        resetNativeNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageIsLoading = false
        updateNavigationVisibility()
        updateInsets(force: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageIsLoading = false
        resetNativeNavigation()
        disableNativeNavigation()
        restoreWebNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageIsLoading = false
        resetNativeNavigation()
        disableNativeNavigation()
        restoreWebNavigation()
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
        pageIsLoading = true
        resetNativeNavigation()
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
