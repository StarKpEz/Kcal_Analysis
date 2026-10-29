import Foundation
import UIKit

/// Opens a verified DeepSeek app entry before falling back to its website.
/// The injected opener keeps URL routing testable without launching another app.
final class ExternalAppLauncher {
    typealias Opener = (URL, [UIApplication.OpenExternalURLOptionsKey: Any], @escaping (Bool) -> Void) -> Void
    typealias Completion = (Result<[String: Any], Error>) -> Void

    static let deepSeekAppURL = URL(string: "https://applink.deepseek.com/")!
    static let deepSeekSchemeURL = URL(string: "dpsk://chat/new")!
    static let deepSeekWebURL = URL(string: "https://chat.deepseek.com/")!

    private let opener: Opener

    init(opener: @escaping Opener = { url, options, completion in
        let open = { UIApplication.shared.open(url, options: options, completionHandler: completion) }
        if Thread.isMainThread { open() }
        else { DispatchQueue.main.async(execute: open) }
    }) {
        self.opener = opener
    }

    func openDeepSeek(preferred: String? = nil, completion: @escaping Completion) {
        var attempts: [Attempt] = []
        if let preferred, let url = Self.externalURL(preferred), !Self.isDefaultWebEntry(url) {
            attempts.append(Attempt(url: url, options: [:], target: "custom"))
        }
        // DeepSeek's AASA explicitly associates the bare applink domain with its
        // iOS app. A failed app-only attempt must not open its download website.
        attempts.append(Attempt(url: Self.deepSeekAppURL, options: [.universalLinksOnly: true], target: "app"))
        // This new-chat scheme is also used by DeepSeek's own public web client.
        // It carries no prompt, login token, or health data.
        if !attempts.contains(where: { $0.url == Self.deepSeekSchemeURL }) {
            attempts.append(Attempt(url: Self.deepSeekSchemeURL, options: [:], target: "app"))
        }
        attempts.append(Attempt(url: Self.deepSeekWebURL, options: [:], target: "web"))
        open(attempts, at: 0, completion: completion)
    }

    func openExternal(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        guard Self.isAllowedExternalURL(url) else { completion?(false); return }
        opener(url, [:]) { completion?($0) }
    }

    static func isAllowedExternalURL(_ url: URL) -> Bool {
        let denied = ["file", "javascript", "data", "kcalapp", "blob", "about", "applewebdata"]
        guard url.absoluteString.count <= 8192,
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty, !denied.contains(scheme),
              url.user == nil, url.password == nil else { return false }
        if scheme == "https" || scheme == "http" {
            guard let host = url.host, !host.isEmpty else { return false }
        }
        return true
    }

    private static func externalURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8192,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: trimmed), isAllowedExternalURL(url) else { return nil }
        return url
    }

    private static func isDefaultWebEntry(_ url: URL) -> Bool {
        // Existing backups may have saved the old default website explicitly.
        // Such a value must still receive the new app-first routing behavior.
        url.scheme?.lowercased() == "https"
            && ["chat.deepseek.com", "applink.deepseek.com"].contains(url.host?.lowercased() ?? "")
            && (url.path.isEmpty || url.path == "/")
            && (url.port == nil || url.port == 443)
            && url.query == nil && url.fragment == nil
    }

    private struct Attempt {
        let url: URL
        let options: [UIApplication.OpenExternalURLOptionsKey: Any]
        let target: String
    }

    private func open(_ attempts: [Attempt], at index: Int, completion: @escaping Completion) {
        guard index < attempts.count else {
            completion(.failure(NativeFailure("cannot_open", "无法打开 DeepSeek，请手动切换后粘贴提问文字，或使用“仅复制文字”重试。")))
            return
        }
        let attempt = attempts[index]
        opener(attempt.url, attempt.options) { opened in
            if opened { completion(.success(["opened": true, "target": attempt.target])) }
            else { self.open(attempts, at: index + 1, completion: completion) }
        }
    }
}
