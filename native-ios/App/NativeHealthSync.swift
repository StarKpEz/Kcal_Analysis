import Foundation
import SwiftUI

struct NativeHealthReview {
    let title: String
    let details: [String]
    let canCommit: Bool
    let commit: @MainActor () async throws -> String
}

struct NativeSleepSource: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Native-only interaction state. HealthKit callbacks cannot save records: only
/// confirmImport invokes the reviewed transaction supplied by NativeAppModel.
@MainActor
final class NativeHealthSyncModel: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, authorizing, reading, reviewing, ready, saving, saved, failed
    }
    struct Timeouts {
        var diagnostic: TimeInterval = 10
        var authorization: TimeInterval = 120
        var read: TimeInterval = 60
        var review: TimeInterval = 20
    }
    typealias PrepareReview = @MainActor ([String: Any], String, String) async throws -> NativeHealthReview

    @Published var fromDate: Date { didSet { invalidateReview() } }
    @Published var throughDate: Date { didSet { invalidateReview() } }
    @Published var selectedSleepSource = "" {
        didSet {
            if selectedSleepSource.isEmpty { defaults?.removeObject(forKey: "kcal.native.sleepSource") }
            else { defaults?.set(selectedSleepSource, forKey: "kcal.native.sleepSource") }
            invalidateReview()
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = "选择日期后，读取 Apple 健康并检查导入预览。"
    @Published private(set) var errorText: String?
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var sources: [NativeSleepSource] = []
    @Published private(set) var review: NativeHealthReview?
    @Published private(set) var authorizationPending = false
    @Published private(set) var automaticRefreshEnabled = false
    let storageIssue: String?

    private let health: NativeHealthProviding
    private let prepareReview: PrepareReview
    private let timeouts: Timeouts
    private let defaults: UserDefaults?
    private var operation: UUID?
    private var authorizationToken: UUID?
    private var timeoutTask: Task<Void, Never>?

    init(health: NativeHealthProviding = HealthKitService.shared, storageIssue: String? = nil,
         timeouts: Timeouts = Timeouts(), now: Date = Date(), defaults: UserDefaults? = .standard,
         prepareReview: @escaping PrepareReview) {
        self.health = health
        self.storageIssue = storageIssue
        self.timeouts = timeouts
        self.defaults = defaults
        self.prepareReview = prepareReview
        let today = Calendar.current.startOfDay(for: now)
        self.throughDate = today
        self.fromDate = Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today
        self.automaticRefreshEnabled = defaults?.bool(forKey: "kcal.native.autoSync") ?? false
        if let source = defaults?.string(forKey: "kcal.native.sleepSource"), !source.isEmpty, source.count <= 512 {
            self.selectedSleepSource = source
            self.sources = [NativeSleepSource(id: source, name: "此前选择的来源")]
        }
        if let issue = storageIssue {
            self.phase = .failed
            self.message = "本地记录暂时无法修改"
            self.errorText = issue
        }
    }

    var isBusy: Bool {
        [.checking, .authorizing, .reading, .reviewing, .saving].contains(phase)
    }
    var canStart: Bool { !isBusy && !authorizationPending && storageIssue == nil }
    var canCommit: Bool { phase == .ready && review?.canCommit == true && storageIssue == nil }
    var canClose: Bool { phase != .saving }

    func setAutomaticRefreshEnabled(_ enabled: Bool) {
        automaticRefreshEnabled = enabled
        defaults?.set(enabled, forKey: "kcal.native.autoSync")
    }

    func start() {
        guard canStart else { return }
        review = nil
        errorText = nil
        diagnostics = Self.deviceDiagnostics()
        guard health.isAvailable else {
            fail("这台设备暂时无法使用 Apple 健康，请在支持健康数据的 iPhone 上重试。")
            return
        }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: fromDate)
        let through = calendar.startOfDay(for: throughDate)
        guard from <= through, through <= calendar.startOfDay(for: Date()),
              let days = calendar.dateComponents([.day], from: from, to: through).day, days < 3_660 else {
            fail("请选择今天及以前的日期，开始日期不能晚于结束日期，一次最多读取 3,660 天。")
            return
        }
        let id = UUID()
        operation = id
        let startDay = Self.dayKey(from), endDay = Self.dayKey(through)
        let source = selectedSleepSource
        if let diagnosticProvider = health as? NativeHealthDiagnosticProviding {
            begin(.checking, message: "正在检查 Apple 健康连接…", id: id, timeout: timeouts.diagnostic)
            diagnosticProvider.diagnostics { [weak self] result in
                Task { @MainActor in
                    guard let self = self, self.isCurrent(id, phase: .checking) else { return }
                    switch result {
                    case .failure(let error): self.fail(error, context: "健康连接检查失败")
                    case .success(let details):
                        self.recordDiagnostics(details)
                        self.authorize(id: id, from: startDay, through: endDay, source: source)
                    }
                }
            }
        } else {
            authorize(id: id, from: startDay, through: endDay, source: source)
        }
    }

    private func authorize(id: UUID, from: String, through: String, source: String) {
        begin(.authorizing, message: "正在请求健康读取授权。若出现系统权限页，请完成选择。", id: id,
              timeout: timeouts.authorization)
        authorizationToken = id
        authorizationPending = true
        // start() and this method run on MainActor. The real adapter also explicitly
        // schedules requestAuthorization on DispatchQueue.main.
        health.authorize { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                if self.authorizationToken == id {
                    self.authorizationToken = nil
                    self.authorizationPending = false
                }
                guard self.isCurrent(id, phase: .authorizing) else { return }
                switch result {
                case .failure(let error): self.fail(error, context: "健康授权请求失败")
                case .success:
                    self.diagnostics.append("授权请求已返回；这不代表每一项读取权限都已允许。")
                    self.read(id: id, from: from, through: through, source: source)
                }
            }
        }
    }

    private func read(id: UUID, from: String, through: String, source: String) {
        begin(.reading, message: "正在读取所选日期的健康记录…", id: id, timeout: timeouts.read)
        let parameters: [String: Any] = ["from": from, "through": through, "sleepSource": source]
        health.sync(params: parameters) { [weak self] result in
            Task { @MainActor in
                guard let self = self, self.isCurrent(id, phase: .reading) else { return }
                switch result {
                case .failure(let error): self.fail(error, context: "健康记录读取失败")
                case .success(let document):
                    self.updateSources(document["sleepSources"] as? [[String: String]] ?? [])
                    let notes = document["notes"] as? [String] ?? []
                    self.diagnostics.append(contentsOf: notes)
                    self.begin(.reviewing, message: "正在检查导入预览…", id: id, timeout: self.timeouts.review)
                    do {
                        let preview = try await self.prepareReview(document, from, through)
                        guard self.isCurrent(id, phase: .reviewing) else { return }
                        self.timeoutTask?.cancel()
                        self.timeoutTask = nil
                        self.operation = nil
                        self.review = preview
                        self.phase = .ready
                        self.message = preview.canCommit ? "读取完成，请核对下面的预览，再确认保存。" : "本次没有可保存的更新。已有记录保持不变。"
                    } catch {
                        guard self.isCurrent(id, phase: .reviewing) else { return }
                        self.fail(error, context: "无法准备导入预览")
                    }
                }
            }
        }
    }

    func confirmImport() {
        guard canCommit, let preview = review else { return }
        let id = UUID()
        operation = id
        phase = .saving
        message = "正在保存已确认的健康记录…"
        errorText = nil
        // No timeout or cancel during the atomic save: hiding an in-progress
        // transaction would falsely imply that nothing was saved.
        Task { @MainActor in
            do {
                let result = try await preview.commit()
                guard self.isCurrent(id, phase: .saving) else { return }
                self.operation = nil
                self.review = nil
                self.phase = .saved
                self.message = result
            } catch {
                guard self.isCurrent(id, phase: .saving) else { return }
                self.review = nil
                self.fail(error, context: "健康记录保存失败")
            }
        }
    }

    func cancel() {
        guard canClose else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        operation = nil
        review = nil
        if isBusy {
            phase = .idle
            message = "已停止本次读取，未保存任何健康记录。"
        }
    }

    private func invalidateReview() {
        guard !isBusy, phase == .ready || phase == .saved else { return }
        review = nil
        phase = .idle
        message = "选项已改变，请重新读取并检查预览。"
    }

    private func updateSources(_ values: [[String: String]]) {
        var seen = Set<String>()
        sources = values.compactMap { value in
            guard let id = value["id"], !id.isEmpty, seen.insert(id).inserted else { return nil }
            return NativeSleepSource(id: id, name: value["name"] ?? "健康来源")
        }
        // Keep a previously selected source represented so Picker never points
        // to a missing tag. It remains explicit; do not silently mix sources.
        if !selectedSleepSource.isEmpty, !sources.contains(where: { $0.id == selectedSleepSource }) {
            sources.append(NativeSleepSource(id: selectedSleepSource, name: "此前选择的来源（当前范围无数据）"))
        }
    }

    private func begin(_ phase: Phase, message: String, id: UUID, timeout: TimeInterval) {
        timeoutTask?.cancel()
        self.phase = phase
        self.message = message
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)) }
            catch { return }
            guard let self = self, self.isCurrent(id, phase: phase) else { return }
            let hint = phase == .authorizing
                ? "系统授权请求尚未返回。请先完成可能打开的权限页；若始终没有出现权限页，请保留下面的诊断信息。请求返回前不会再次发起授权，也不会保存记录。"
                : "此次操作等待过久，未保存健康记录。可以重试或缩小日期范围。"
            self.fail("\(hint)\n[KcalAnalysis.HealthSync / timeout.\(phase)]")
        }
    }

    private func isCurrent(_ id: UUID, phase: Phase) -> Bool { operation == id && self.phase == phase }

    private func fail(_ error: Error, context: String) {
        let value = error as NSError
        var detail = "\(context)：\(value.localizedDescription)\n[\(value.domain) / \(value.code)]"
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += "\n系统原因：\(underlying.localizedDescription) [\(underlying.domain) / \(underlying.code)]"
        }
        fail(detail)
    }

    private func fail(_ detail: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        operation = nil
        review = nil
        phase = .failed
        message = "本次同步未完成，已有记录保持不变。"
        errorText = detail
    }

    private func recordDiagnostics(_ details: [String: Any]) {
        switch details["authorizationRequestStatus"] as? String {
        case "shouldRequest": diagnostics.append("系统报告有尚需询问的数据类型，下一步请求权限页。")
        case "unnecessary": diagnostics.append("系统报告已询问这些数据类型，本次可能不再显示权限页；这不代表已获读取权限。")
        default: diagnostics.append("系统未确定是否需要显示权限页，仍将发起授权请求。")
        }
        diagnostics.append("健康数据可用；健康读取用途说明已配置。最终安装包的签名能力仍以系统实际响应为准。")
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func deviceDiagnostics() -> [String] {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return ["App \(version)（\(build)） · \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "标识：\(bundle.bundleIdentifier ?? "未知")"]
    }
}

@MainActor
struct NativeHealthSyncView: View {
    @ObservedObject var model: NativeHealthSyncModel
    var automaticStatus: String? = nil
    let onClose: () -> Void

    var body: some View {
        Form {
            Section {
                Text("读取体重、能量、训练和睡眠，在确认预览后保存到本机。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("日期范围") {
                dateRow("开始日期", selection: $model.fromDate, identifier: "health-sync-from")
                dateRow("结束日期", selection: $model.throughDate, identifier: "health-sync-through")
            }.disabled(model.isBusy)
            if !model.sources.isEmpty {
                Section {
                    Picker("睡眠来源", selection: $model.selectedSleepSource) {
                        Text("自动选择（仅限单一来源）").tag("")
                        ForEach(model.sources) { source in Text(source.name).tag(source.id) }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("health-sync-sleep-source")
                } footer: {
                    Text("多个来源时请选择一个，再重新读取。不会叠加多个设备的睡眠记录。")
                }.disabled(model.isBusy)
            }
            Section {
                Toggle("回到 App 时自动刷新", isOn: Binding(
                    get: { model.automaticRefreshEnabled },
                    set: { enabled in
                        model.setAutomaticRefreshEnabled(enabled)
                        if enabled { model.start() }
                    }))
                    .disabled(model.isBusy || model.authorizationPending || (!model.canStart && !model.automaticRefreshEnabled))
                    .accessibilityIdentifier("health-sync-automatic")
                if let status = automaticStatus, !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("health-sync-automatic-status")
                }
            } footer: {
                Text("启用时先连接 Apple 健康。之后回到 App 时刷新最近 7 天，最多每分钟一次；自动刷新不覆盖手动记录，也不会弹出权限页。")
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isBusy { ProgressView().accessibilityLabel("正在同步") }
                    Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("health-sync-status")
                    if let error = model.errorText {
                        Label { Text(error).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("health-sync-error")
                    }
                    if model.authorizationPending && !model.isBusy {
                        Text("仍在等待上一次系统授权请求结束。若长时间没有变化，可退出并重新打开 App 后重试。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                Button(model.phase == .idle ? "连接并读取 Apple 健康" : "重新读取 Apple 健康") { model.start() }
                    .disabled(!model.canStart).accessibilityIdentifier("health-sync-read")
            }
            if let preview = model.review {
                Section("导入预览") {
                    Text(preview.title).font(.headline)
                    ForEach(Array(preview.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if preview.canCommit {
                        Button("确认保存到本机") { model.confirmImport() }
                            .disabled(!model.canCommit).accessibilityIdentifier("health-sync-confirm")
                    }
                }
            }
            Section {
                Text("iOS 不会告知 App 哪些读取权限被拒绝。没有可读数据也可能是日期内没有记录、设备尚未同步或历史访问范围受限。可在健康 App 的个人资料中检查本 App 的数据访问权限。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.diagnostics.isEmpty {
                    DisclosureGroup("连接诊断与读取说明") {
                        ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, value in
                            Text(value).font(.footnote).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }.accessibilityIdentifier("health-sync-diagnostics")
                }
            }
        }
        .navigationTitle("Apple 健康")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(model.isBusy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.phase == .saved ? "完成" : "关闭") { model.cancel(); onClose() }
                    .disabled(!model.canClose)
            }
        }
    }

    private func dateRow(_ title: String, selection: Binding<Date>, identifier: String) -> some View {
        // Separate full-width rows with stacked labels avoid horizontal date
        // control compression at 320 pt and with accessibility text sizes.
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            DatePicker(title, selection: selection, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.compact).labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }.padding(.vertical, 6)
    }
}
