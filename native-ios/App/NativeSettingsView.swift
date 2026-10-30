import SwiftUI
import UniformTypeIdentifiers

struct NativeTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw NativeFailure("file_encoding", "文件不是有效的 UTF-8 文本。")
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

@MainActor
struct NativeSettingsView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kcal = ""
    @State private var p = ""
    @State private var f = ""
    @State private var c = ""
    @State private var sex = "male"
    @State private var birthYear = ""
    @State private var height = ""
    @State private var bodyFat = ""
    @State private var baselineWeight = ""
    @State private var activity = 1.375
    @State private var harris = false
    @State private var deepSeek = ""
    @State private var issue: String?
    @State private var status: String?
    @State private var document = NativeTextDocument()
    @State private var exporting = false
    @State private var exportType: UTType = .json
    @State private var exportName = ""
    @State private var markBackup = false
    @State private var deleting = false
    @State private var loaded = false
    @State private var loadedSettings: Data?
    private let activities = [(1.2, "久坐"), (1.375, "轻度活动"), (1.55, "中度活动"), (1.725, "高度活动"), (1.9, "极高活动")]

    var body: some View {
        Form {
            if let issue { Section { NativeInlineError(message: issue) } }
            if let status { Section { Text(status).font(.callout).textSelection(.enabled) } }
            if model.isReadOnly { Section("记录保护") { NativeInlineError(message: model.error ?? "本地快照读取异常，请先导出恢复文件。") } }
            Section("每日目标") {
                NativeNumberField(title: "热量", text: $kcal, unit: "kcal")
                NativeNumberField(title: "蛋白质", text: $p, unit: "g")
                NativeNumberField(title: "脂肪", text: $f, unit: "g")
                NativeNumberField(title: "碳水", text: $c, unit: "g")
            }
            Section {
                Picker("计算公式使用的性别", selection: $sex) { Text("男").tag("male"); Text("女").tag("female") }
                NativeNumberField(title: "出生年份", text: $birthYear)
                NativeNumberField(title: "身高", text: $height, unit: "cm")
                NativeNumberField(title: "体脂率（可选）", text: $bodyFat, unit: "%")
                NativeNumberField(title: "基准体重（可选）", text: $baselineWeight, unit: "kg")
                Picker("日常活动水平", selection: $activity) { ForEach(activities, id: \.0) { value, title in Text(title).tag(value) } }
                Toggle("优先使用 Harris-Benedict 公式", isOn: $harris)
            } header: { Text("身体档案") } footer: {
                Text("用于估算代谢与消耗。有体脂率时使用 Katch-McArdle；日常称重在健康页面记录。")
            }
            Section("DeepSeek") {
                TextField("自定义链接（留空优先打开 App）", text: $deepSeek, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("默认优先唤醒已安装的 DeepSeek，无法唤醒时打开网页。") .font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("保存目标与设置") { saveSettings() }.disabled(model.isReadOnly).accessibilityIdentifier("save-settings") }
            Section("备份与恢复") {
                Button(model.isReadOnly ? "导出原始恢复文件" : "导出完整 JSON 备份") { exportBackup() }
                    .accessibilityIdentifier("export-backup")
                NavigationLink("从完整备份恢复") { NativeImportView(model: model, kind: .backup) }
                NavigationLink("导入历史对话记录") { NativeImportView(model: model, kind: .chat) }
                Button("导出所选日期的 CSV") { exportCSV() }.disabled(model.isReadOnly)
                Text(storageSummary).font(.footnote).foregroundStyle(.secondary)
                Text("App 与 PWA 各自保存。更新或续签前请导出备份，并保持相同签名身份覆盖安装。") .font(.footnote).foregroundStyle(.secondary)
            }
            Section("管理所选日期") {
                Text(model.dayKey).font(.subheadline).foregroundStyle(.secondary)
                Button("清空这一天的饮食", role: .destructive) { deleting = true }.disabled(model.isReadOnly)
            }
            Section("关于") {
                LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                Text("开发阶段请使用虚构备份验收。完成 App 验收后，再确认迁移日常记录。") .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { load() }
        .onReceive(model.$snapshot.dropFirst()) { snapshot in
            // A restored backup can replace settings while this parent Form stays
            // alive. Do not later save stale fields over the imported values.
            if settingsSignature(snapshot) != loadedSettings { load(snapshot: snapshot, force: true) }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
            switch result {
            case .success:
                status = "文件已导出，请在「文件」App 中确认。"
                if markBackup {
                    do { try model.mutate("patch", payload: ["patch": ["meta": ["lastBackup": NativeAppModel.dayKey(Date())]]]) }
                    catch { issue = "备份已导出，但备份日期未能记录：" + error.localizedDescription }
                }
            case .failure(let error): issue = "未能导出：" + error.localizedDescription
            }
            markBackup = false
        }
        .confirmationDialog("清空 \(model.dayKey) 的全部饮食记录？", isPresented: $deleting, titleVisibility: .visible) {
            Button("清空这一天的饮食", role: .destructive) {
                do { try model.mutate("clearDiet", payload: ["date": model.dayKey]); status = "已清空这一天的饮食。" }
                catch { issue = error.localizedDescription }
            }
        } message: { Text("体重、能量、训练和睡眠会保留。此操作不能撤销。") }
    }
    private var storageSummary: String {
        let entries = model.snapshot["entries"] as? [String: Any] ?? [:]
        let weights = model.snapshot["weight"] as? [String: Any] ?? [:]
        return "已保存 \(entries.count) 天饮食、\(weights.count) 天体重。完整 JSON 包含全部历史与设置；CSV 仅供查看饮食。"
    }
    private func settingsSignature(_ snapshot: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["settings": snapshot["settings"] ?? [:], "body": snapshot["body"] ?? [:]], options: [.sortedKeys])
    }
    private func load(snapshot incoming: [String: Any]? = nil, force: Bool = false) {
        guard force || !loaded else { return }; loaded = true
        let current = incoming ?? model.snapshot
        loadedSettings = settingsSignature(current)
        let settings = current["settings"] as? [String: Any] ?? [:]
        let body = current["body"] as? [String: Any] ?? [:]
        kcal = NativeValues.text(settings["kcal"]); p = NativeValues.text(settings["p"])
        f = NativeValues.text(settings["f"]); c = NativeValues.text(settings["c"])
        deepSeek = settings["dsScheme"] as? String ?? ""; sex = body["sex"] as? String ?? "male"
        birthYear = NativeValues.text(body["birthYear"]); height = NativeValues.text(body["heightCm"])
        bodyFat = NativeValues.text(body["bodyFat"]); baselineWeight = NativeValues.text(body["weightKg"])
        activity = (body["activity"] as? NSNumber)?.doubleValue ?? 1.375; harris = body["preferHarris"] as? Bool ?? false
    }
    private func saveSettings() {
        do {
            var settings = model.snapshot["settings"] as? [String: Any] ?? [:]
            for (key, title, value) in [("kcal", "热量目标", kcal), ("p", "蛋白质目标", p), ("f", "脂肪目标", f), ("c", "碳水目标", c)] { settings[key] = try NativeValues.decimal(value, name: title) }
            settings["dsScheme"] = deepSeek.trimmingCharacters(in: .whitespacesAndNewlines)
            var body = model.snapshot["body"] as? [String: Any] ?? [:]
            body["sex"] = sex; body["activity"] = activity; body["preferHarris"] = harris
            for (key, title, value) in [("birthYear", "出生年份", birthYear), ("heightCm", "身高", height), ("bodyFat", "体脂率", bodyFat), ("weightKg", "基准体重", baselineWeight)] {
                body[key] = try NativeValues.decimal(value, name: title, optional: true).map { $0 as Any } ?? ""
            }
            try model.mutate("patch", payload: ["patch": ["settings": settings, "body": body]])
            issue = nil; status = "设置已保存。"
        } catch { issue = error.localizedDescription; status = nil }
    }
    private func exportBackup() {
        do {
            let value = try model.query("exportBackup")
            guard let text = value["text"] as? String else { throw NativeFailure("export_failed", "无法生成完整备份。") }
            document = NativeTextDocument(text: text); exportType = .json
            let recovery = value["recovery"] as? Bool == true
            exportName = (recovery ? "kcal-recovery-" : "kcal-backup-") + NativeAppModel.dayKey(Date())
            markBackup = !recovery; exporting = true; issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func exportCSV() {
        do {
            let summary = try model.query("summary", payload: ["date": model.dayKey])
            var rows = [["日期", "餐次", "食物", "克数", "热量", "蛋白质", "脂肪", "碳水"]]
            for meal in summary["meals"] as? [[String: Any]] ?? [] {
                for item in meal["items"] as? [[String: Any]] ?? [] {
                    rows.append([model.dayKey, meal["name"] as? String ?? "", NativeValues.text(item["name"])] + ["grams", "kcal", "protein", "fat", "carbs"].map { NativeValues.text(item[$0]) })
                }
            }
            let escaped = rows.map { row in row.map { value -> String in
                let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",") }.joined(separator: "\r\n")
            document = NativeTextDocument(text: "\u{FEFF}" + escaped); exportType = .commaSeparatedText
            exportName = "kcal-" + model.dayKey; markBackup = false; exporting = true
        } catch { issue = error.localizedDescription }
    }
}

@MainActor
struct NativeImportView: View {
    enum Kind { case backup, health, chat }
    @ObservedObject var model: NativeAppModel
    let kind: Kind
    @State private var text = ""
    @State private var preview: [String: Any]?
    @State private var issue: String?
    @State private var status: String?
    @State private var choosing = false
    @State private var loading = false
    @State private var confirming = false
    @State private var mode = "merge"
    private var title: String { kind == .health ? "导入健康记录" : kind == .chat ? "导入历史对话" : "恢复完整备份" }
    var body: some View {
        Form {
            Section {
                Text(kind == .health ? "支持日汇总、精简样本和能量边界 JSON。先核对预览，确认后一次保存。" : "先选文件或粘贴内容，核对日期、条目与导入方式后保存。开发期间请使用虚构备份。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("选择文件", systemImage: "doc") { choosing = true }.disabled(loading)
                TextEditor(text: $text).frame(minHeight: 170).font(.body.monospaced())
                    .accessibilityLabel("待导入内容").disabled(loading)
                PasteButton(payloadType: String.self) { values in text = values.joined(separator: "\n") }.disabled(loading)
                Button("检查并预览") { prepare() }.disabled(text.isEmpty || loading)
            }
            if loading { Section { ProgressView("正在读取文件…") } }
            if let issue { Section { NativeInlineError(message: issue) } }
            if let status { Section { Text(status).textSelection(.enabled) } }
            if let preview {
                Section("导入预览") {
                    ForEach(Array((preview["details"] as? [String] ?? []).enumerated()), id: \.offset) { _, detail in Text(detail) }
                    ForEach(Array((preview["notes"] as? [String] ?? []).enumerated()), id: \.offset) { _, detail in Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    if kind != .health {
                        Picker("导入方式", selection: $mode) {
                            Text("合并，保留已有日期").tag("merge")
                            Text("覆盖备份包含的类别").tag("replace")
                        }
                        Text("覆盖会替换备份包含的整类历史；合并时，同日健康类别以备份为准。建议先导出当前完整备份。") .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("确认保存") { confirming = true }
                        .disabled(kind == .health && NativeValues.number(preview["updates"]) == 0)
                        .accessibilityIdentifier("confirm-import")
                }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: text) { _, _ in preview = nil; status = nil; issue = nil }
        .fileImporter(isPresented: $choosing, allowedContentTypes: kind == .chat ? [.plainText, .json] : [.json, .plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { read(url) }
            case .failure(let error): issue = error.localizedDescription
            }
        }
        .confirmationDialog(kind == .health ? "保存预览中的健康记录？" : (mode == "replace" ? "覆盖备份包含的整类记录？" : "合并这些记录？"), isPresented: $confirming, titleVisibility: .visible) {
            Button("确认保存", role: kind != .health && mode == "replace" ? .destructive : nil) { save() }
            Button("取消", role: .cancel) { }
        } message: { Text("未提供的类别保留；取消不会写入记录。") }
    }
    private func prepare() {
        do {
            preview = try model.query(kind == .health ? "previewHealth" : "previewRestore", payload: ["text": text])
            if model.isReadOnly && kind != .health { mode = "replace" }
            issue = nil; status = nil
        } catch { preview = nil; issue = error.localizedDescription }
    }
    private func save() {
        do {
            let result = try model.mutate(kind == .health ? "importHealth" : kind == .chat ? "importChat" : "restore", payload: ["text": text, "mode": mode])
            status = kind == .health ? "已保存 \(Int(NativeValues.number(result["updates"]))) 项日记录。" : "已完成导入。请核对历史日期与记录。"
            preview = nil; issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func read(_ url: URL) {
        loading = true; preview = nil
        Task {
            do {
                let limit = kind == .health ? 5 * 1024 * 1024 : 96 * 1024 * 1024
                let raw = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let bytes = try handle.read(upToCount: limit + 1) ?? Data()
                    guard bytes.count <= limit else { throw NativeFailure("file_too_large", "文件过大，请选择范围更小的文件。") }
                    guard let text = String(data: bytes, encoding: .utf8) else { throw NativeFailure("file_encoding", "请选择 UTF-8 编码的 JSON 或文本。") }
                    return text
                }.value
                text = raw; issue = nil
            } catch { issue = error.localizedDescription }
            loading = false
        }
    }
}
