import SwiftUI
import UIKit

@MainActor
struct NativeDietView: View {
    @ObservedObject var model: NativeAppModel
    var onRecorderPresented: (Bool) -> Void = { _ in }
    @State private var summary: [String: Any] = [:]
    @State private var issue: String?
    @State private var recording: MealChoice?
    private var meals: [[String: Any]] {
        (summary["meals"] as? [[String: Any]] ?? []).filter {
            $0["key"] as? String != "__legacy" || !($0["items"] as? [[String: Any]] ?? []).isEmpty
        }
    }
    private var totals: [String: Any] { summary["totals"] as? [String: Any] ?? [:] }
    private var settings: [String: Any] { model.snapshot["settings"] as? [String: Any] ?? [:] }

    var body: some View {
        List {
            Section { NativeDateHeader(model: model) }
            if let issue { Section { NativeInlineError(message: issue) } }
            if model.isReadOnly { Section { NativeInlineError(message: model.error ?? "本地记录处于只读保护状态，请先导出恢复文件。") } }
            Section("当日摄入") {
                NativeNutritionSummary(totals: totals, settings: settings)
            }
            ForEach(meals.indices, id: \.self) { offset in
                let meal = meals[offset]
                let key = meal["key"] as? String ?? "lunch"
                let name = meal["name"] as? String ?? "未分餐"
                let items = meal["items"] as? [[String: Any]] ?? []
                Section {
                    ForEach(items.indices, id: \.self) { index in
                        NavigationLink {
                            NativeFoodEditor(model: model, date: model.dayKey, meal: key, index: index, item: items[index])
                        } label: { NativeFoodRow(item: items[index]) }
                        .accessibilityIdentifier("food-row-\(key)-\(index)")
                    }
                    if key != "__legacy" {
                        Button { recording = MealChoice(key: key, name: name, date: model.dayKey) } label: {
                            Label("记录\(name)", systemImage: "plus.circle")
                        }.disabled(model.isReadOnly)
                        .accessibilityIdentifier("add-food-" + key)
                    } else if items.isEmpty { EmptyView() }
                } header: {
                    Text(name + " · " + NativeValues.display((meal["totals"] as? [String: Any])?["kcal"]) + " kcal")
                }
            }
            Section {
                NavigationLink("饮食统计") { NativeFoodHistoryView(model: model) }
                NavigationLink("导入历史对话记录") { NativeImportView(model: model, kind: .chat) }
            }
        }
        .navigationTitle("饮食")
        .task(id: model.dayKey) { refresh() }
        .onReceive(model.$snapshot.dropFirst()) { _ in refresh() }
        .onChange(of: recording != nil) { _, presented in onRecorderPresented(presented) }
        .sheet(item: $recording) { meal in
            NavigationStack { NativeMealRecorder(model: model, date: meal.date, meal: meal.key, name: meal.name) }
        }
    }
    private func refresh() {
        do { summary = try model.query("summary", payload: ["date": model.dayKey]); issue = nil }
        catch { issue = error.localizedDescription }
    }
    private struct MealChoice: Identifiable { let key: String; let name: String; let date: String; var id: String { key + date } }
}

struct NativeFoodRow: View {
    let item: [String: Any]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item["name"] as? String ?? "未命名").foregroundStyle(.primary)
            Text("\(NativeValues.display(item["kcal"])) kcal" + (NativeValues.number(item["grams"]) > 0 ? " · \(NativeValues.display(item["grams"], digits: 1)) g" : ""))
                .font(.subheadline).foregroundStyle(.secondary)
            Text("蛋白质 \(NativeValues.display(item["protein"], digits: 1)) · 脂肪 \(NativeValues.display(item["fat"], digits: 1)) · 碳水 \(NativeValues.display(item["carbs"], digits: 1)) g")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

struct NativeNutritionSummary: View {
    let totals: [String: Any]
    let settings: [String: Any]
    private let metrics = [("p", "蛋白质", Color.blue), ("f", "脂肪", Color.orange), ("c", "碳水", Color.purple)]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NativeValues.display(totals["kcal"]) + " kcal").font(.largeTitle.bold()).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text("每日目标 \(NativeValues.display(settings["kcal"])) kcal").font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(metrics, id: \.0) { key, name, color in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(name)  \(NativeValues.display(totals[key], digits: 1)) / \(NativeValues.display(settings[key])) g").font(.subheadline).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: min(max(NativeValues.number(totals[key]), 0), max(NativeValues.number(settings[key]), 1)), total: max(NativeValues.number(settings[key]), 1)).tint(color)
                        .accessibilityLabel(name).accessibilityValue("\(NativeValues.display(totals[key])) 克，目标 \(NativeValues.display(settings[key])) 克")
                }
            }
        }.padding(.vertical, 8)
    }
}

@MainActor
struct NativeMealRecorder: View {
    @ObservedObject var model: NativeAppModel
    let date: String
    let meal: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var answer = ""
    @State private var items: [[String: Any]] = []
    @State private var issue: String?
    @State private var message: String?
    @State private var manual = false
    @State private var manualSaved = false
    @State private var draft: DraftChoice?
    private let launcher = ExternalAppLauncher()
    var body: some View {
        Form {
            Section { Text(date).foregroundStyle(.secondary) }
            Section("1. 描述这一餐") {
                TextField("食物、份量与烹饪方式", text: $description, axis: .vertical).lineLimit(3...8)
                Button("复制提问词并打开 DeepSeek") { copyPrompt(openApp: true) }
                    .accessibilityIdentifier("open-deepseek")
                Button("仅复制提问词") { copyPrompt(openApp: false) }
                Text("照片请在 DeepSeek 中自行选择。返回这里粘贴回答，再核对保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("2. 粘贴回答") {
                TextEditor(text: $answer).frame(minHeight: 160).accessibilityLabel("DeepSeek 回答")
                PasteButton(payloadType: String.self) { values in answer = values.joined(separator: "\n"); items = [] }
                Button("解析回答") { parse() }.disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let issue { Section { NativeInlineError(message: issue) } }
            if let message { Section { Text(message).font(.callout) } }
            if !items.isEmpty {
                Section("3. 核对 \(items.count) 项食物") {
                    ForEach(items.indices, id: \.self) { index in
                        Button { draft = DraftChoice(index: index, item: items[index]) } label: { NativeFoodRow(item: items[index]) }
                    }
                    Text("点选食物可修正名称、重量和营养值，确认保存前不会写入记录。") .font(.footnote).foregroundStyle(.secondary)
                    Button("保存到\(name)") {
                        do { try model.mutate("addFood", payload: ["date": date, "meal": meal, "items": items]); dismiss() }
                        catch { issue = error.localizedDescription }
                    }.disabled(model.isReadOnly).accessibilityIdentifier("save-parsed-food")
                }
            }
            Section { Button("手动填写食物") { manual = true } }
        }
        .navigationTitle("记录\(name)").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onChange(of: answer) { _, _ in items = [] }
        .sheet(isPresented: $manual, onDismiss: {
            // Finish the child transition before closing the meal sheet.
            if manualSaved { dismiss() }
        }) {
            NavigationStack { NativeFoodEditor(model: model, date: date, meal: meal, index: nil, item: [:], onSaved: { manualSaved = true }) }
        }
        .sheet(item: $draft) { selected in
            NavigationStack {
                NativeFoodEditor(model: model, date: date, meal: meal, index: nil, item: selected.item, onDraftSaved: { value in
                    if items.indices.contains(selected.index) { items[selected.index] = value }
                })
            }
        }
    }
    private func parse() {
        do {
            let result = try model.query("parseFood", payload: ["text": answer])
            items = result["items"] as? [[String: Any]] ?? []
            issue = items.isEmpty ? "没有识别到食物，请保留热量和营养素单位，或使用手动填写。" : nil
            message = nil
        } catch { issue = error.localizedDescription; items = [] }
    }
    private func copyPrompt(openApp: Bool) {
        do {
            let prompt = try model.query("foodPrompt", payload: ["description": description, "meal": meal])
            guard let text = prompt["text"] as? String else { return }
            UIPasteboard.general.string = text
            if !openApp { message = "提问词已复制。"; issue = nil; return }
            let settings = model.snapshot["settings"] as? [String: Any] ?? [:]
            launcher.openDeepSeek(preferred: settings["dsScheme"] as? String) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let response): message = response["target"] as? String == "web" ? "已复制提问词，并打开网页版。" : "已复制提问词，请在 DeepSeek 中粘贴。"
                    case .failure(let error): issue = error.localizedDescription
                    }
                }
            }
        } catch { issue = error.localizedDescription }
    }
    private struct DraftChoice: Identifiable { let index: Int; let item: [String: Any]; var id: Int { index } }
}

@MainActor
struct NativeFoodEditor: View {
    @ObservedObject var model: NativeAppModel
    let date: String
    let meal: String
    let index: Int?
    let item: [String: Any]
    var onSaved: () -> Void = {}
    var onDraftSaved: (([String: Any]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var grams = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var carbs = ""
    @State private var destination = "lunch"
    @State private var issue: String?
    @State private var deleting = false
    @State private var loaded = false
    private let meals = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐")]
    var body: some View {
        Form {
            Section { Text(date).foregroundStyle(.secondary) }
            Section("食物") {
                TextField("名称", text: $name).accessibilityIdentifier("food-name")
                NativeNumberField(title: "重量（可选）", text: $grams, unit: "g")
                NativeNumberField(title: "热量", text: $kcal, unit: "kcal")
                NativeNumberField(title: "蛋白质", text: $protein, unit: "g")
                NativeNumberField(title: "脂肪", text: $fat, unit: "g")
                NativeNumberField(title: "碳水", text: $carbs, unit: "g")
            }
            if NativeValues.number(item["grams"]) > 0 {
                Section {
                    Button("按新重量换算原营养值") { scale() }
                    Text("以打开页面时的原记录为基准，按克数等比例换算。保存后才修改记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let issue { Section { NativeInlineError(message: issue) } }
            Section { Button(onDraftSaved == nil ? "保存食物" : "完成修正") { save() }.disabled(onDraftSaved == nil && model.isReadOnly).accessibilityIdentifier("save-food") }
            if let index {
                Section("调整餐次") {
                    Picker("移到", selection: $destination) { ForEach(meals, id: \.0) { key, title in Text(title).tag(key) } }
                    Button("移动这项食物") {
                        do { try model.mutate("moveFood", payload: ["date": date, "meal": meal, "index": index, "toMeal": destination, "expectedItem": item]); dismiss() }
                        catch { issue = error.localizedDescription }
                    }.disabled(model.isReadOnly || destination == meal)
                }
                Section { Button("删除这项食物", role: .destructive) { deleting = true }.disabled(model.isReadOnly) }
            }
        }
        .navigationTitle(onDraftSaved != nil ? "修正待保存食物" : index == nil ? "手动记录" : "编辑食物").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear {
            guard !loaded else { return }; loaded = true
            name = NativeValues.text(item["name"]); grams = NativeValues.text(item["grams"])
            kcal = NativeValues.text(item["kcal"]); protein = NativeValues.text(item["protein"])
            fat = NativeValues.text(item["fat"]); carbs = NativeValues.text(item["carbs"])
            destination = meals.contains(where: { $0.0 == meal }) ? meal : "lunch"
        }
        .confirmationDialog("删除这项食物？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let index else { return }
                do { try model.mutate("deleteFood", payload: ["date": date, "meal": meal, "index": index, "expectedItem": item]); dismiss() }
                catch { issue = error.localizedDescription }
            }
        }
    }
    private func scale() {
        do {
            let value = try NativeValues.decimal(grams, name: "重量") ?? 0
            guard value > 0 else { throw NativeFailure("invalid_grams", "换算重量须大于 0。") }
            let factor = value / NativeValues.number(item["grams"])
            kcal = String(NativeValues.number(item["kcal"]) * factor)
            protein = String(NativeValues.number(item["protein"]) * factor)
            fat = String(NativeValues.number(item["fat"]) * factor)
            carbs = String(NativeValues.number(item["carbs"]) * factor)
            issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func save() {
        do {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeFailure("food_name", "请填写食物名称。") }
            var value: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
            for (key, title, raw) in [("kcal", "热量", kcal), ("protein", "蛋白质", protein), ("fat", "脂肪", fat), ("carbs", "碳水", carbs)] {
                value[key] = try NativeValues.decimal(raw, name: title)
            }
            value["grams"] = try NativeValues.decimal(grams, name: "重量", optional: true) ?? 0
            if let onDraftSaved { onDraftSaved(value); dismiss(); return }
            if let index { try model.mutate("editFood", payload: ["date": date, "meal": meal, "index": index, "item": value, "expectedItem": item]) }
            else { try model.mutate("addFood", payload: ["date": date, "meal": meal, "items": [value]]) }
            onSaved(); dismiss()
        } catch { issue = error.localizedDescription }
    }
}

@MainActor
struct NativeFoodHistoryView: View {
    @ObservedObject var model: NativeAppModel
    @State private var days = 7
    @State private var results: [[String: Any]] = []
    @State private var issue: String?
    var body: some View {
        List {
            Section {
                NativeDateHeader(model: model)
                Picker("统计范围", selection: $days) { Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }.pickerStyle(.segmented)
                Text("截至所选日期。未记录的日期单独标记，不补为零。") .font(.footnote).foregroundStyle(.secondary)
            }
            if let issue { Section { NativeInlineError(message: issue) } }
            Section("每天记录") {
                ForEach(results.indices, id: \.self) { index in
                    let row = results[index]
                    let totals = row["totals"] as? [String: Any] ?? [:]
                    let energy = row["energy"] as? [String: Any] ?? [:]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row["date"] as? String ?? "").font(.headline)
                        Text(energy["hasIntake"] as? Bool == true ? NativeValues.display(totals["kcal"]) + " kcal" : "未记录")
                        if energy["hasIntake"] as? Bool == true {
                            Text("蛋白质 \(NativeValues.display(totals["p"])) · 脂肪 \(NativeValues.display(totals["f"])) · 碳水 \(NativeValues.display(totals["c"])) g")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle("饮食统计").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.dayKey)-\(days)") { refresh() }
        .onReceive(model.$snapshot.dropFirst()) { _ in refresh() }
    }
    private func refresh() {
        guard let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: model.selectedDate) else { return }
        do { results = Array((try model.query("range", payload: ["from": NativeAppModel.dayKey(from), "through": model.dayKey])["days"] as? [[String: Any]] ?? []).reversed()); issue = nil }
        catch { issue = error.localizedDescription }
    }
}
