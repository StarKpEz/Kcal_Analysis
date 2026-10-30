import Foundation
import Combine

/// Replanned immediately before a synchronous atomic snapshot transaction.
/// Automatic refresh never replaces records that require manual confirmation.
struct NativeHealthAutomaticReview {
    let updates: Int
    let conflicts: Int
    let commit: @MainActor () throws -> String
}

@MainActor
final class NativeHealthAutoSyncModel: ObservableObject {
    typealias PrepareReview = @MainActor ([String: Any], String, String) throws -> NativeHealthAutomaticReview

    @Published private(set) var isRunning = false
    @Published private(set) var message: String?
    @Published private(set) var errorText: String?

    private let health: NativeHealthProviding
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let timeout: TimeInterval
    private let prepareReview: PrepareReview
    private let canApply: @MainActor () -> Bool
    private var lastAttempt: Date?
    private var operation: UUID?
    private var timeoutTask: Task<Void, Never>?

    init(health: NativeHealthProviding = HealthKitService.shared,
         defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init,
         timeout: TimeInterval = 60,
         canApply: @escaping @MainActor () -> Bool = { true },
         prepareReview: @escaping PrepareReview) {
        self.health = health
        self.defaults = defaults
        self.now = now
        self.timeout = timeout
        self.canApply = canApply
        self.prepareReview = prepareReview
    }

    /// Called only on foreground/resume. The caller also excludes open editors,
    /// sheets, navigation details and read-only storage, then rechecks via canApply.
    func refreshIfEnabled(allowed: Bool) {
        guard allowed, !isRunning, defaults?.bool(forKey: "kcal.native.autoSync") == true,
              canApply() else { return }
        let current = now()
        if let previous = lastAttempt, current.timeIntervalSince(previous) < 60 { return }
        guard health.isAvailable else {
            message = "当前设备无法自动读取 Apple 健康。"
            return
        }
        lastAttempt = current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let through = calendar.startOfDay(for: current)
        guard let from = calendar.date(byAdding: .day, value: -6, to: through) else { return }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let fromKey = formatter.string(from: from), throughKey = formatter.string(from: through)
        let source = defaults?.string(forKey: "kcal.native.sleepSource") ?? ""
        let id = UUID()
        operation = id
        isRunning = true
        errorText = nil
        message = "正在刷新最近 7 天的健康记录…"
        timeoutTask?.cancel()
        let delay = UInt64(max(0.001, timeout) * 1_000_000_000)
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard let self = self, self.operation == id else { return }
            self.finish(message: "自动刷新等待过久，未保存记录。请在 Apple 健康页面手动重试。",
                        error: "[KcalAnalysis.HealthSync / timeout.automatic]")
        }
        // Preserve the previous app's opt-in refresh. Automatic work never asks
        // for authorization or interprets an empty result as denied access.
        health.sync(params: ["from": fromKey, "through": throughKey, "sleepSource": source]) { [weak self] result in
            Task { @MainActor in
                guard let self = self, self.operation == id else { return }
                guard self.defaults?.bool(forKey: "kcal.native.autoSync") == true, self.canApply() else {
                    self.cancel()
                    return
                }
                switch result {
                case .failure(let error):
                    self.fail(error)
                case .success(let document):
                    do {
                        let review = try self.prepareReview(document, fromKey, throughKey)
                        guard self.operation == id,
                              self.defaults?.bool(forKey: "kcal.native.autoSync") == true,
                              self.canApply() else {
                            self.cancel()
                            return
                        }
                        guard review.conflicts == 0 else {
                            self.finish(message: "读取结果包含已有手动记录。请打开 Apple 健康页面核对；本次自动刷新未写入。")
                            return
                        }
                        guard review.updates > 0 else {
                            self.finish(message: "最近 7 天没有可保存的更新。若尚未连接，请手动连接 Apple 健康。")
                            return
                        }
                        // No suspension between the last guard and commit. The
                        // domain layer must replan with automatic=true and CAS.
                        let result = try review.commit()
                        self.finish(message: result)
                    } catch {
                        guard self.operation == id else { return }
                        self.fail(error)
                    }
                }
            }
        }
    }

    /// Invalidates in-flight reads. HealthKit may still call back, but a cancelled
    /// operation cannot prepare a review or write a snapshot.
    func cancel() {
        guard operation != nil else { return }
        finish(message: "自动刷新已停止，未保存记录。")
    }

    private func fail(_ error: Error) {
        let value = error as NSError
        finish(message: "自动刷新未完成，已有记录保持不变。请在 Apple 健康页面重试。",
               error: "\(value.localizedDescription) [\(value.domain) / \(value.code)]")
    }

    private func finish(message: String, error: String? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        operation = nil
        isRunning = false
        self.message = message
        errorText = error
    }
}
