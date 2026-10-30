import SwiftUI
import Charts
import Foundation
import CoreFoundation

// Native presentation only. All saves and calculations enter the preserved domain
// through NativeAppModel; browsing, charts and selection never persist a snapshot.
@MainActor
struct HealthDashboard: View {
    @ObservedObject var model: NativeAppModel
    var onSync: () -> Void = {}
    var onImport: () -> Void = {}
    @State private var energy: [String: Any] = [:]
    @State private var queryError: String?

    private var training: [String: Any]? { HealthUI.day(model.snapshot, "training", model.dayKey) }
    private var sleep: [String: Any]? { HealthUI.day(model.snapshot, "sleep", model.dayKey) }
    private var sessions: [[String: Any]] { training?["sessions"] as? [[String: Any]] ?? [] }
    private var latestWeight: (String?, Double?) { HealthUI.latestWeight(model.snapshot, through: model.dayKey) }

    var body: some View {
        List {
            Section { NativeDateHeader(model: model) }
            if let queryError { Section { HealthFeedback(message: queryError, failed: true) } }
            Section("健康记录") {
                NavigationLink {
                    NativeEnergyDetail(model: model, onSync: onSync, onImport: onImport)
                } label: {
                    HealthMetricRow(title: "能量", symbol: "flame", color: .orange,
                        value: HealthUI.flag(energy, "hasBurn") ? HealthUI.number(energy["burn"]) + " kcal" : "未记录",
                        detail: energyDescription)
                }
                .accessibilityIdentifier("health-energy")
                NavigationLink {
                    NativeWeightDetail(model: model)
                } label: {
                    HealthMetricRow(title: "体重", symbol: "scalemass", color: .green,
                        value: latestWeight.1.map { HealthUI.number($0) + " kg" } ?? "未记录",
                        detail: latestWeight.0.map { "最近称重 · " + $0 } ?? (latestWeight.1 == nil ? "记录体重，查看完整趋势" : "身体档案值"))
                }
                .accessibilityIdentifier("health-weight")
                NavigationLink {
                    NativeTrainingDetail(model: model)
                } label: {
                    HealthMetricRow(title: "训练", symbol: "figure.run", color: .blue,
                        value: training == nil ? "未记录" : "\(sessions.count) 次",
                        detail: training == nil ? "查看并记录训练" : HealthUI.duration(sessions.reduce(0) { $0 + (HealthUI.value($1["durationMinutes"]) ?? 0) }))
                }
                .accessibilityIdentifier("health-training")
                NavigationLink {
                    NativeSleepDetail(model: model)
                } label: {
                    HealthMetricRow(title: "睡眠", symbol: "bed.double", color: .purple,
                        value: HealthUI.value(sleep?["asleepMinutes"]).map(HealthUI.duration) ?? "未记录",
                        detail: sleep == nil ? "归到醒来的日期" : "实际睡眠 · " + HealthUI.source(sleep))
                }
                .accessibilityIdentifier("health-sleep")
            }
            Section("Apple 健康") {
                Button(action: onSync) { Label("连接与同步 Apple 健康", systemImage: "heart.text.clipboard") }
                    .accessibilityIdentifier("health-sync")
                Button(action: onImport) { Label("导入健康 JSON", systemImage: "square.and.arrow.down") }
                Text("活动与静息能量相加；训练能量不再重复计入消耗。网页与 App 的记录分别保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.isReadOnly {
                Section { HealthFeedback(message: model.error ?? "本地记录暂不可写，请先导出恢复文件并检查存储提示。", failed: true) }
            }
        }
        .navigationTitle("健康")
        .task(id: model.dayKey) { refresh() }
        .onReceive(model.$snapshot.dropFirst()) { _ in refresh() }
    }

    private var energyDescription: String {
        if model.dayKey == HealthUI.key(Date()) {
            guard HealthUI.flag(energy, "hasBurn") else { return "录入健康能量或完善身体档案" }
            return energy["source"] as? String == "estimate" ? "全天公式估算 · 查看详情" : "今日累计 · 全天差额次日查看"
        }
        if HealthUI.flag(energy, "canCompare"), let deficit = HealthUI.value(energy["deficit"]) {
            return (deficit >= 0 ? "记录缺口 " : "记录盈余 ") + HealthUI.number(abs(deficit)) + " kcal" +
                (energy["source"] as? String == "estimate" ? " · 公式估算" : "")
        }
        return energy["source"] as? String == "estimate" ? "公式估算 · 查看详情" : "查看摄入与消耗"
    }

    private func refresh() {
        do { energy = try model.query("energy", payload: ["date": model.dayKey]); queryError = nil }
        catch { energy = [:]; queryError = error.localizedDescription }
    }
}

@MainActor
struct NativeEnergyDetail: View {
    @ObservedObject var model: NativeAppModel
    var onSync: () -> Void
    var onImport: () -> Void
    @State private var energy: [String: Any] = [:]
    @State private var days: [HealthEnergyDay] = []
    @State private var active = ""
    @State private var basal = ""
    @State private var feedback: String?
    @State private var failed = false
    @State private var confirmClear = false
    private var saved: [String: Any]? { HealthUI.day(model.snapshot, "burn", model.dayKey) }
    private var bodyProfile: [String: Any] { model.snapshot["body"] as? [String: Any] ?? [:] }

    var body: some View {
        Form {
            Section { NativeDateHeader(model: model) }
            if let feedback { Section { HealthFeedback(message: feedback, failed: failed) } }
            balanceSection
            entrySection
            if HealthUI.flag(energy, "hasBody") { profileSection }
            historySection
            importSection
        }
        .navigationTitle("能量").navigationBarTitleDisplayMode(.inline)
        .task(id: model.dayKey) { refresh(resetInputs: true) }
        .onReceive(model.$snapshot.dropFirst()) { _ in refresh(resetInputs: false) }
        .confirmationDialog("清除 " + model.dayKey + " 的能量录入？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除录入", role: .destructive) { clear() }
        } message: { Text("只清除当天活动与静息能量，之后恢复公式估算。") }
    }

    private var balanceSection: some View {
        Section("摄入与消耗") {
            HealthValueRow("已记录摄入", intakeText)
            HealthValueRow(isEstimated ? "总消耗 · 公式估算" : "总消耗 · 健康能量", burnText)
            if HealthUI.flag(energy, "hasBurn") {
                HealthValueRow("静息 / 基础代谢", HealthUI.number(energy["rest"]) + " kcal")
                HealthValueRow("活动", HealthUI.number(energy["active"]) + " kcal")
            }
            balanceComparison
            Text("消耗来自健康能量录入，或 BMR × 活动系数估算；不再叠加训练热量和食物热效应。饮食漏记会影响差额，差额不代表实际减重。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var balanceComparison: some View {
        if HealthUI.flag(energy, "canCompare"), let deficit = HealthUI.value(energy["deficit"]) {
            HealthValueRow(deficitTitle(deficit), HealthUI.number(abs(deficit)) + " kcal")
        } else {
            Text(model.dayKey == HealthUI.key(Date()) ? "今天仍在累计，全天差额次日查看。" : "有饮食与消耗记录后才比较差额。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var entrySection: some View {
        Section {
            HealthNumberField(title: "活动能量（kcal）", text: $active, identifier: "energy-active")
            HealthNumberField(title: "静息能量（kcal）", text: $basal, identifier: "energy-basal")
            Button("保存当日能量", action: save).disabled(model.isReadOnly)
                .accessibilityIdentifier("energy-save")
            if saved != nil {
                Button("清除当日能量", role: .destructive) { confirmClear = true }.disabled(model.isReadOnly)
            }
        } header: { Text("录入健康能量") } footer: { Text(entryFooter) }
    }
    private var profileSection: some View {
        Section("身体档案与公式") {
            profileValues
            if let formula = energy["formula"] as? String { Text(formula).font(.footnote).foregroundStyle(.secondary) }
            targetReference
            Text("身体档案与摄入目标可在设置中调整。公式结果仅作参考，不自动修改目标。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var profileValues: some View {
        HealthValueRow("最近体重", profileWeightText)
        HealthValueRow("身高", profileHeightText)
        HealthValueRow("基础代谢 BMR", HealthUI.number(energy["bmr"]) + " kcal")
        HealthValueRow("活动系数", HealthUI.number(bodyProfile["activity"]))
        HealthValueRow("估算总消耗 TDEE", estimatedTotalText)
    }
    @ViewBuilder private var targetReference: some View {
        if let target = energy["target"] as? [String: Any], HealthUI.flag(target, "ok") {
            HealthValueRow("参考摄入", HealthUI.number(target["target"]) + " kcal")
            Text(HealthUI.flag(target, "clipped") ? "参考值已按原有摄入下限调整；下限不保证个人适用。" : "参考值按身体档案估算。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var historySection: some View {
        Section("近 14 天 · 截至 " + model.dayKey) {
            if days.contains(where: { $0.hasIntake || $0.hasBurn }) { energyChart }
            else { Text("尚无可显示的摄入或消耗。").foregroundStyle(.secondary) }
            energyStatistics
            DisclosureGroup("每日数值与来源") {
                ForEach(days) { day in energyDayRow(day) }
            }
        }
    }
    private func energyDayRow(_ day: HealthEnergyDay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.key).font(.subheadline)
            Text(energyDayDescription(day)).font(.footnote)
            Text(day.estimated ? "公式估算" : day.closed ? "历史录入" : "今日累计")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var importSection: some View {
        Section {
            Button("同步 Apple 健康", action: onSync)
            Button("导入健康 JSON", action: onImport)
        }
    }
    private var isEstimated: Bool { energy["source"] as? String == "estimate" }
    private var intakeText: String { HealthUI.flag(energy, "hasIntake") ? HealthUI.number(energy["intake"]) + " kcal" : "未记录" }
    private var burnText: String { HealthUI.flag(energy, "hasBurn") ? HealthUI.number(energy["burn"]) + " kcal" : "无数据" }
    private func deficitTitle(_ deficit: Double) -> String {
        let title = deficit >= 0 ? "记录缺口" : "记录盈余"
        return title + (isEstimated ? " · 公式估算" : "")
    }
    private var entryFooter: String {
        guard let saved else { return "两项都需填写。0 可以保存；缺失不当作 0。" }
        return HealthUI.source(saved) + " · " + HealthUI.timestamp(saved["updatedAt"]) + "。手动保存会替换当天两项能量。"
    }
    private var profileWeightText: String {
        guard let value = HealthUI.latestWeight(model.snapshot, through: model.dayKey).1 else { return "未提供" }
        return HealthUI.number(value) + " kg"
    }
    private var profileHeightText: String {
        guard let value = HealthUI.value(bodyProfile["heightCm"]) else { return "未提供" }
        return HealthUI.number(value) + " cm"
    }
    private var estimatedTotalText: String {
        let bmr = HealthUI.value(energy["bmr"]) ?? 0
        let activity = HealthUI.value(bodyProfile["activity"]) ?? 1.2
        return HealthUI.number(bmr * activity) + " kcal"
    }
    private func energyDayDescription(_ day: HealthEnergyDay) -> String {
        let intake = day.hasIntake ? HealthUI.number(day.intake) + " kcal" : "未记录"
        let burn = day.hasBurn ? HealthUI.number(day.burn) + " kcal" : "无数据"
        return "摄入 \(intake)；消耗 \(burn)"
    }

    private var energyChart: some View {
        Chart(days) { day in
            if day.hasIntake {
                BarMark(x: .value("日期", day.date), y: .value("kcal", day.intake))
                    .position(by: .value("类别", "摄入")).foregroundStyle(by: .value("类别", "摄入"))
                    .opacity(day.closed ? 1 : 0.4)
            }
            if day.hasBurn {
                BarMark(x: .value("日期", day.date), y: .value("kcal", day.burn))
                    .position(by: .value("类别", "消耗")).foregroundStyle(by: .value("类别", "消耗"))
                    .opacity(day.estimated || !day.closed ? 0.4 : 1)
            }
        }
        .chartForegroundStyleScale(domain: ["摄入", "消耗"], range: [Color.blue, Color.orange])
        .chartXScale(domain: energyChartDomain)
        .frame(height: 200)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits)) } }
        .accessibilityLabel("近十四天摄入与消耗，蓝色为摄入，橙色为消耗。每日明细可在下方展开。")
    }
    private var energyChartDomain: ClosedRange<Date> {
        let from = days.first?.date ?? model.selectedDate.addingTimeInterval(-86_400)
        let through = days.last?.date ?? model.selectedDate
        return from...through
    }

    @ViewBuilder private var energyStatistics: some View {
        let food = days.filter { $0.closed && $0.hasIntake }
        let measured = days.filter { $0.closed && $0.measured }
        let paired = measured.filter(\.hasIntake)
        let estimates = days.filter { $0.closed && $0.estimated && $0.hasBurn }
        HealthValueRow("已记录摄入平均（\(food.count) 天）", average(food.map(\.intake)))
        HealthValueRow("健康能量平均（\(measured.count) 天）", average(measured.map(\.burn)))
        HealthValueRow("同日记录平均差额（\(paired.count) 天）", average(paired.map { $0.burn - $0.intake }))
        HealthValueRow("公式估算平均（\(estimates.count) 天）", average(estimates.map(\.burn)))
        Text("平均值不含今天，缺失日不补零。浅色柱表示今日累计或公式估算。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func average(_ values: [Double]) -> String {
        values.isEmpty ? "暂无" : HealthUI.number(values.reduce(0, +) / Double(values.count)) + " kcal"
    }
    private func refresh(resetInputs: Bool) {
        do {
            energy = try model.query("energy", payload: ["date": model.dayKey])
            days = try (0..<14).reversed().map { offset in
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: model.selectedDate) ?? model.selectedDate
                let key = HealthUI.key(date)
                return HealthEnergyDay(key: key, raw: try model.query("energy", payload: ["date": key]))
            }
            if resetInputs {
                active = HealthUI.input(saved?["active"]); basal = HealthUI.input(saved?["basal"])
                feedback = nil
            }
        } catch { feedback = error.localizedDescription; failed = true }
    }
    private func save() {
        do {
            let a = try HealthUI.requiredNumber(active, label: "活动能量")
            let b = try HealthUI.requiredNumber(basal, label: "静息能量")
            _ = try model.mutate("saveEnergy", payload: ["date": model.dayKey, "active": a, "basal": b])
            feedback = "已保存 " + model.dayKey + " 的健康能量。"; failed = false
            refresh(resetInputs: false)
        } catch { feedback = error.localizedDescription; failed = true }
    }
    private func clear() {
        do {
            _ = try model.mutate("clearCategory", payload: ["date": model.dayKey, "category": "burn"])
            active = ""; basal = ""; feedback = "已清除当日能量。"; failed = false
            refresh(resetInputs: false)
        } catch { feedback = error.localizedDescription; failed = true }
    }
}

@MainActor
struct NativeWeightDetail: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: NativeAppModel
    @State private var mode = "all"
    @State private var anchor = ""
    @State private var window: [String: Any] = [:]
    @State private var reverse: [String: Any] = [:]
    @State private var records: [HealthWeightPoint] = []
    @State private var selectedKey = ""
    @State private var chartDate: Date?
    @State private var weight = ""
    @State private var feedback: String?
    @State private var failed = false
    @State private var confirmClear = false
    private var selected: HealthWeightPoint? { records.first { $0.key == selectedKey } ?? records.last }
    private var meta: [String: Any]? {
        guard let selected else { return nil }
        return HealthUI.day(model.snapshot, "weightMeta", selected.key)
    }
    private var currentSaved: Double? { HealthUI.value((model.snapshot["weight"] as? [String: Any])?[model.dayKey]) }

    var body: some View {
        Form {
            Section { NativeDateHeader(model: model) }
            if let feedback { Section { HealthFeedback(message: feedback, failed: failed) } }
            trendSection
            entrySection
            reverseSection
        }
        .navigationTitle("体重").navigationBarTitleDisplayMode(.inline)
        .task(id: model.dayKey) { anchor = model.dayKey; selectedKey = ""; weight = HealthUI.input(currentSaved); refresh() }
        .onReceive(model.$snapshot.dropFirst()) { _ in refresh() }
        .onChange(of: mode) { _, _ in anchor = model.dayKey; selectedKey = ""; refresh() }
        .onChange(of: chartDate) { _, date in selectNearest(to: date) }
        .confirmationDialog("删除 " + model.dayKey + " 的称重？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("删除当日称重", role: .destructive) { clear() }
        } message: { Text("仅删除当天称重与其来源，其他日期保留。") }
    }

    private var trendSection: some View {
        Section("体重趋势") {
            rangePicker
            periodNavigation
            trendSummary
            if records.isEmpty {
                Text("这个区间尚无称重。").foregroundStyle(.secondary)
            } else {
                trendRecords
            }
        }
    }
    @ViewBuilder private var trendSummary: some View {
        HealthValueRow(mode == "all" ? "累计体重变化" : "区间体重变化", deltaText)
        HealthValueRow("首次", weightText(window["first"]))
        HealthValueRow("末次", weightText(window["last"]))
        HealthValueRow("记录天数", String(records.count))
    }
    @ViewBuilder private var trendRecords: some View {
        weightChart
        selectedRecord
        recordSlider
        Text("仅连接真实日期的称重，缺测不补值。点选图表或移动滑块查看每次记录。")
            .font(.footnote).foregroundStyle(.secondary)
        allRecords
    }
    @ViewBuilder private var selectedRecord: some View {
        if let selected {
            HealthValueRow(selected.key, HealthUI.number(selected.kg) + " kg")
            Text(selectedSourceText).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var recordSlider: some View {
        Slider(value: pointSelection, in: sliderRange, step: 1)
            .disabled(records.count < 2)
            .accessibilityLabel("逐条查看称重记录")
            .accessibilityValue(selectedAccessibilityText)
    }
    private var allRecords: some View {
        DisclosureGroup("查看区间全部记录（\(records.count) 天）") {
            ForEach(records.reversed()) { record in
                Button { selectedKey = record.key } label: {
                    HealthValueRow(record.key, HealthUI.number(record.kg) + " kg")
                }.buttonStyle(.plain)
            }
        }
    }
    private var entrySection: some View {
        Section("记录 " + model.dayKey + " 的体重") {
            HealthNumberField(title: "体重（kg）", text: $weight, identifier: "weight-input")
            Button("保存体重", action: save).disabled(model.isReadOnly).accessibilityIdentifier("weight-save")
            if currentSaved != nil {
                Button("删除当日称重", role: .destructive) { confirmClear = true }.disabled(model.isReadOnly)
            }
        }
    }
    private var reverseSection: some View {
        Section("近 28 天消耗推算 · 截至 " + model.dayKey) {
            if HealthUI.flag(reverse, "ok") {
                HealthValueRow("趋势推算（参考）", HealthUI.number(reverse["value"]) + " kcal/天")
                Text(reversePeriodText).font(.footnote)
            } else {
                Text(reverseExplanation).foregroundStyle(.secondary)
            }
            Text("按近 28 天真实体重趋势与已记录摄入推算，漏记与体重水分会影响结果，不视为实测消耗，不自动调整摄入目标。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var deltaText: String {
        guard let value = HealthUI.value(window["delta"]) else { return "—" }
        let sign = value > 0 ? "+" : ""
        return sign + HealthUI.number(value) + " kg"
    }
    private func weightText(_ raw: Any?) -> String {
        guard let value = HealthUI.value(raw) else { return "—" }
        return HealthUI.number(value) + " kg"
    }
    private var selectedSourceText: String {
        let source = HealthUI.source(meta)
        guard let measuredAt = meta?["measuredAt"] else { return source }
        return source + " · " + HealthUI.timestamp(measuredAt)
    }
    private var selectedAccessibilityText: String {
        guard let selected else { return "无记录" }
        return selected.key + "，" + HealthUI.number(selected.kg) + " kg"
    }
    private var sliderRange: ClosedRange<Double> { 0...Double(max(1, records.count - 1)) }
    private var reversePeriodText: String {
        let from = reverse["from"] as? String ?? ""
        let through = reverse["to"] as? String ?? ""
        let days = HealthUI.number(reverse["days"])
        return "\(from) 至 \(through)，区间 \(days) 天均有饮食记录。"
    }
    private func selectNearest(to date: Date?) {
        guard let date else { return }
        let nearest = records.min { left, right in
            abs(left.date.timeIntervalSince(date)) < abs(right.date.timeIntervalSince(date))
        }
        if let nearest { selectedKey = nearest.key }
    }

    @ViewBuilder private var rangePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("时间范围", selection: $mode) { rangeOptions }.pickerStyle(.menu)
        } else {
            Picker("时间范围", selection: $mode) { rangeOptions }.pickerStyle(.segmented)
        }
    }
    @ViewBuilder private var rangeOptions: some View {
        Text("全部").tag("all"); Text("周").tag("week"); Text("月").tag("month"); Text("年").tag("year")
    }
    private var periodNavigation: some View {
        HStack {
            Button { step("previous") } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                .disabled(!HealthUI.flag(window, "canPrevious")).accessibilityLabel("上一个区间")
            Spacer(minLength: 4)
            Text((window["from"] as? String ?? model.dayKey) + " – " + (window["through"] as? String ?? model.dayKey))
                .font(.footnote).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { step("next") } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                .disabled(!HealthUI.flag(window, "canNext")).accessibilityLabel("下一个区间")
        }.buttonStyle(.borderless)
    }
    private var pointSelection: Binding<Double> {
        Binding(get: { Double(records.firstIndex { $0.key == selected?.key } ?? max(0, records.count - 1)) }, set: {
            if records.indices.contains(Int($0)) { selectedKey = records[Int($0)].key }
        })
    }
    private var weightChart: some View {
        Chart {
            ForEach(records) { record in
                LineMark(x: .value("日期", record.date), y: .value("体重 kg", record.kg))
                    .interpolationMethod(.linear).foregroundStyle(.green)
                PointMark(x: .value("日期", record.date), y: .value("体重 kg", record.kg))
                    .foregroundStyle(.green)
                    .symbol { Circle().strokeBorder(Color.green, lineWidth: 2).frame(width: 8, height: 8) }
                    .accessibilityLabel(record.key).accessibilityValue(HealthUI.number(record.kg) + " kg")
            }
            if let selected {
                RuleMark(x: .value("所选日期", selected.date)).foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("日期", selected.date), y: .value("体重 kg", selected.kg))
                    .foregroundStyle(.green).symbolSize(65)
            }
        }
        .chartYScale(domain: weightDomain)
        .chartXScale(domain: chartDomain)
        .chartXSelection(value: $chartDate)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits)) } }
        .frame(height: 220)
        .accessibilityLabel("真实日期体重趋势")
    }
    private var weightDomain: ClosedRange<Double> {
        let low = records.map(\.kg).min() ?? 0, high = records.map(\.kg).max() ?? 1
        let padding = max(0.5, (high - low) * 0.15)
        return max(0, low - padding)...(high + padding)
    }
    private var chartDomain: ClosedRange<Date> {
        let from = HealthUI.date(window["from"] as? String ?? "") ?? model.selectedDate
        let through = HealthUI.date(window["through"] as? String ?? "") ?? from
        // A single measurement stays one real point; only the axis receives padding.
        return from < through ? from...through : from.addingTimeInterval(-43_200)...from.addingTimeInterval(43_200)
    }
    private var reverseExplanation: String {
        switch reverse["reason"] as? String {
        case "noWeight": return "近 28 天至少需要 4 次体重记录。"
        case "tooShort": return "体重记录跨度不足 14 天。"
        case "fewLogs": return "体重区间内仍有日期没有饮食记录（" + HealthUI.number(reverse["logged"]) + "/" + HealthUI.number(reverse["days"]) + " 天）。"
        case "unstableTrend": return "体重趋势波动较大，暂不推算。"
        default: return "数据不足，暂不推算消耗。"
        }
    }
    private func step(_ key: String) { if let next = window[key] as? String { anchor = next; selectedKey = ""; refresh() } }
    private func refresh() {
        do {
            window = try model.query("weightWindow", payload: ["mode": mode, "anchor": anchor.isEmpty ? model.dayKey : anchor, "asOf": model.dayKey])
            records = (window["records"] as? [[String: Any]] ?? []).compactMap(HealthWeightPoint.init)
            if !records.contains(where: { $0.key == selectedKey }) { selectedKey = records.last?.key ?? "" }
            reverse = try model.query("energy", payload: ["date": model.dayKey])["trend"] as? [String: Any] ?? [:]
        } catch { feedback = error.localizedDescription; failed = true }
    }
    private func save() {
        do {
            _ = try model.mutate("saveWeight", payload: ["date": model.dayKey, "value": try HealthUI.requiredNumber(weight, label: "体重")])
            feedback = "已保存 " + model.dayKey + " 的体重。"; failed = false; refresh()
        } catch { feedback = error.localizedDescription; failed = true }
    }
    private func clear() {
        do {
            _ = try model.mutate("clearCategory", payload: ["date": model.dayKey, "category": "weight"])
            weight = ""; feedback = "已删除当日称重。"; failed = false; refresh()
        } catch { feedback = error.localizedDescription; failed = true }
    }
}

@MainActor
struct NativeTrainingDetail: View {
    @ObservedObject var model: NativeAppModel
    @State private var editor: HealthTrainingEditorSelection?
    @State private var deleting: HealthTrainingSession?
    @State private var feedback: String?
    @State private var failed = false
    private var day: [String: Any]? { HealthUI.day(model.snapshot, "training", model.dayKey) }
    private var sessions: [HealthTrainingSession] {
        (day?["sessions"] as? [[String: Any]] ?? []).compactMap(HealthTrainingSession.init)
    }

    var body: some View {
        List {
            Section { NativeDateHeader(model: model) }
            if let feedback { Section { HealthFeedback(message: feedback, failed: failed) } }
            Section {
                if sessions.isEmpty {
                    Text(day == nil ? "尚无训练记录" : "当天已记录，没有训练会话").foregroundStyle(.secondary)
                } else {
                    HealthValueRow("训练总时长", HealthUI.duration(sessions.reduce(0) { $0 + $1.minutes }))
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.type).font(.headline)
                            Text(HealthUI.duration(session.minutes)).font(.body).monospacedDigit()
                            if let distance = session.distance { Text("距离 " + HealthUI.number(distance) + " km").font(.subheadline) }
                            if let energy = session.energy { Text("活动能量 " + HealthUI.number(energy) + " kcal").font(.subheadline) }
                            if let start = session.startAt { Text(HealthUI.timestamp(start)).font(.footnote).foregroundStyle(.secondary) }
                            HStack(spacing: 20) {
                                Button { editor = HealthTrainingEditorSelection(date: model.dayKey, session: session) } label: {
                                    Text("编辑").frame(minWidth: 44, minHeight: 44)
                                }
                                    .accessibilityLabel("编辑" + session.type)
                                Button(role: .destructive) { deleting = session } label: {
                                    Text("删除").frame(minWidth: 44, minHeight: 44)
                                }
                                    .accessibilityLabel("删除" + session.type)
                            }.buttonStyle(.borderless).frame(minHeight: 44).disabled(model.isReadOnly)
                        }.padding(.vertical, 4)
                    }
                }
                Button {
                    editor = HealthTrainingEditorSelection(date: model.dayKey, session: nil)
                } label: { Label("记录一次训练", systemImage: "plus") }
                    .disabled(model.isReadOnly).accessibilityIdentifier("training-add")
            } header: { Text("当日训练") } footer: {
                if let day { Text(HealthUI.source(day) + " · " + HealthUI.timestamp(day["updatedAt"])) }
            }
            Section {
                Text("训练活动能量仅用于记录。每日总消耗取活动与静息能量之和，不重复叠加训练热量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("训练").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.dayKey) { _, _ in feedback = nil; deleting = nil }
        .sheet(item: $editor) { selection in
            NavigationStack {
                NativeTrainingEditor(model: model, selection: selection) {
                    feedback = "已保存 " + selection.date + " 的训练。"; failed = false
                }
            }
        }
        .confirmationDialog("删除这次训练？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除训练", role: .destructive) { delete() }
        } message: {
            if let deleting { Text(model.dayKey + " · " + deleting.type + " · " + HealthUI.duration(deleting.minutes)) }
        }
    }

    private func delete() {
        guard let deleting else { return }
        do {
            _ = try model.mutate("deleteTraining", payload: ["date": model.dayKey, "id": deleting.id])
            feedback = "已删除这次训练。"; failed = false
        } catch { feedback = error.localizedDescription; failed = true }
        self.deleting = nil
    }
}

private struct HealthTrainingEditorSelection: Identifiable {
    let date: String
    let session: HealthTrainingSession?
    var id: String { date + ":" + (session?.id ?? "new") }
}

@MainActor
private struct NativeTrainingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NativeAppModel
    let selection: HealthTrainingEditorSelection
    var onSave: () -> Void
    @State private var type: String
    @State private var minutes: String
    @State private var distance: String
    @State private var energy: String
    @State private var error: String?
    private let standardTypes = ["力量训练", "跑步", "步行", "骑行", "游泳", "瑜伽", "其他"]
    private var types: [String] {
        standardTypes.contains(type) ? standardTypes : [type] + standardTypes
    }

    init(model: NativeAppModel, selection: HealthTrainingEditorSelection, onSave: @escaping () -> Void) {
        self.model = model; self.selection = selection; self.onSave = onSave
        _type = State(initialValue: selection.session?.type ?? "力量训练")
        _minutes = State(initialValue: HealthUI.input(selection.session?.minutes))
        _distance = State(initialValue: HealthUI.input(selection.session?.distance))
        _energy = State(initialValue: HealthUI.input(selection.session?.energy))
    }

    var body: some View {
        Form {
            Section {
                Text(selection.date).foregroundStyle(.secondary)
                Picker("训练类型", selection: $type) { ForEach(types, id: \.self) { Text($0).tag($0) } }
                HealthNumberField(title: "时长（分钟）", text: $minutes, identifier: "training-minutes")
                HealthNumberField(title: "距离（km，可选）", text: $distance, identifier: "training-distance")
                HealthNumberField(title: "活动能量（kcal，可选）", text: $energy, identifier: "training-energy")
            } footer: {
                Text("不清楚的距离或能量可以留空；留空不会记成 0。")
            }
            if let error { Section { NativeInlineError(message: error) } }
            Section { Button("保存训练", action: save).disabled(model.isReadOnly).accessibilityIdentifier("training-save") }
        }
        .navigationTitle(selection.session == nil ? "记录训练" : "编辑训练")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }

    private func save() {
        do {
            var input: [String: Any] = ["type": type, "durationMinutes": try HealthUI.requiredNumber(minutes, label: "训练时长")]
            if let value = try NativeValues.decimal(distance, name: "距离", optional: true) { input["distanceKm"] = value }
            if let value = try NativeValues.decimal(energy, name: "活动能量", optional: true) { input["energyKcal"] = value }
            _ = try model.mutate("saveTraining", payload: ["date": selection.date, "id": selection.session?.id ?? "", "input": input])
            onSave(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct NativeSleepDetail: View {
    @ObservedObject var model: NativeAppModel
    @State private var hours = ""
    @State private var minutes = ""
    @State private var includesTimes = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var feedback: String?
    @State private var failed = false
    @State private var confirmClear = false
    private var sleep: [String: Any]? { HealthUI.day(model.snapshot, "sleep", model.dayKey) }
    private var stages: [String: Any]? { sleep?["stages"] as? [String: Any] }

    var body: some View {
        Form {
            Section { NativeDateHeader(model: model) }
            Section {
                if let asleep = HealthUI.value(sleep?["asleepMinutes"]) {
                    Text(HealthUI.duration(asleep)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("实际睡眠 · " + HealthUI.source(sleep)).font(.footnote).foregroundStyle(.secondary)
                    if let startAt = sleep?["startAt"] { HealthValueRow("入睡", HealthUI.timestamp(startAt)) }
                    if let endAt = sleep?["endAt"] { HealthValueRow("醒来", HealthUI.timestamp(endAt)) }
                    HealthValueRow("核心睡眠", stageValue("core"))
                    HealthValueRow("深度睡眠", stageValue("deep"))
                    HealthValueRow("REM 睡眠", stageValue("rem"))
                    let known = (stages ?? [:]).values.compactMap { HealthUI.value($0) }.reduce(0, +)
                    if stages != nil && asleep - known > 1 {
                        Text("另有 " + HealthUI.number(asleep - known) + " 分钟睡眠未细分阶段，已计入实际睡眠。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("尚无睡眠记录").foregroundStyle(.secondary)
                }
            } header: { Text("当日睡眠") } footer: {
                Text("睡眠归到醒来的日期。实际睡眠不包含清醒和卧床时间。")
            }
            Section {
                HealthNumberField(title: "睡眠小时", text: $hours, identifier: "sleep-hours", integer: true)
                HealthNumberField(title: "睡眠分钟（0–59）", text: $minutes, identifier: "sleep-minutes", integer: true)
                Toggle("填写入睡和醒来时间", isOn: $includesTimes)
            } header: { Text("记录实际睡眠") } footer: {
                Text("小时和分钟都需填写，允许明确的 0。手动保存会替换当天睡眠及已导入的分期。")
            }
            if includesTimes {
                Section("入睡时间") { HealthDateTimeFields(value: $start, prefix: "sleep-start") }
                Section("醒来时间") { HealthDateTimeFields(value: $end, prefix: "sleep-end") }
            }
            if let feedback { Section { HealthFeedback(message: feedback, failed: failed) } }
            Section {
                Button("保存睡眠", action: save).disabled(model.isReadOnly).accessibilityIdentifier("sleep-save")
                if sleep != nil { Button("删除当日睡眠", role: .destructive) { confirmClear = true }.disabled(model.isReadOnly) }
            }
        }
        .navigationTitle("睡眠").navigationBarTitleDisplayMode(.inline)
        .task(id: model.dayKey) { reset() }
        .confirmationDialog("删除 " + model.dayKey + " 的睡眠？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("删除当日睡眠", role: .destructive) { clear() }
        } message: { Text("只删除所选醒来日期的睡眠，其他日期保留。") }
    }

    private func stageValue(_ name: String) -> String {
        HealthUI.value(stages?[name]).map { HealthUI.number($0) + " 分钟" } ?? "未提供"
    }
    private func reset() {
        if let duration = HealthUI.value(sleep?["asleepMinutes"]) {
            let rounded = Int(duration.rounded()); hours = String(rounded / 60); minutes = String(rounded % 60)
        } else { hours = ""; minutes = "" }
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: model.selectedDate)
        end = HealthUI.instant(sleep?["endAt"]) ?? calendar.date(byAdding: .hour, value: 7, to: midnight) ?? midnight
        start = HealthUI.instant(sleep?["startAt"]) ?? calendar.date(byAdding: .hour, value: -8, to: end) ?? end
        includesTimes = sleep?["startAt"] != nil && sleep?["endAt"] != nil
        feedback = nil
    }
    private func save() {
        do {
            let input = try HealthUI.sleepInput(hours: hours, minutes: minutes, includesTimes: includesTimes, start: start, end: end)
            _ = try model.mutate("saveSleep", payload: ["date": model.dayKey, "input": input])
            feedback = "已保存 " + model.dayKey + " 的睡眠。"; failed = false
        } catch { feedback = error.localizedDescription; failed = true }
    }
    private func clear() {
        do {
            _ = try model.mutate("clearCategory", payload: ["date": model.dayKey, "category": "sleep"])
            reset(); feedback = "已删除当日睡眠。"; failed = false
        } catch { feedback = error.localizedDescription; failed = true }
    }
}

// Separate native date/time rows keep compact pickers clear at 320 pt and large text.
// They never share an outlined HTML input or an overlaid border.
private struct HealthDateTimeFields: View {
    @Binding var value: Date
    var prefix: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日期").font(.subheadline).foregroundStyle(.secondary)
            DatePicker("日期", selection: $value, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact).accessibilityIdentifier(prefix + "-date")
        }.padding(.vertical, 4)
        VStack(alignment: .leading, spacing: 8) {
            Text("时间").font(.subheadline).foregroundStyle(.secondary)
            DatePicker("时间", selection: $value, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.compact).accessibilityIdentifier(prefix + "-time")
        }.padding(.vertical, 4)
    }
}

private struct HealthFeedback: View {
    var message: String
    var failed: Bool
    var body: some View {
        if failed { NativeInlineError(message: message) }
        else {
            Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }
}

private struct HealthMetricRow: View {
    var title: String
    var symbol: String
    var color: Color
    var value: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(.primary).monospacedDigit()
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

private struct HealthValueRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 0)
                Text(value).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Text(value).monospacedDigit()
            }
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

private struct HealthNumberField: View {
    let title: String
    @Binding var text: String
    let identifier: String
    var integer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(title, text: $text).keyboardType(integer ? .numberPad : .decimalPad)
                .textFieldStyle(.plain).frame(minHeight: 44)
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }.padding(.vertical, 4)
    }
}

struct HealthEnergyDay: Identifiable {
    let key: String
    let date: Date
    let intake: Double
    let burn: Double
    let hasIntake: Bool
    let hasBurn: Bool
    let closed: Bool
    let measured: Bool
    let estimated: Bool
    var id: String { key }
    init(key: String, raw: [String: Any]) {
        self.key = key; date = HealthUI.date(key) ?? .distantPast
        intake = HealthUI.value(raw["intake"]) ?? 0; burn = HealthUI.value(raw["burn"]) ?? 0
        hasIntake = HealthUI.flag(raw, "hasIntake"); hasBurn = HealthUI.flag(raw, "hasBurn")
        closed = HealthUI.flag(raw, "closedDay"); estimated = raw["source"] as? String == "estimate"
        measured = hasBurn && !estimated
    }
}

struct HealthWeightPoint: Identifiable {
    let key: String
    let date: Date
    let kg: Double
    var id: String { key }
    init?(_ raw: [String: Any]) {
        guard let key = raw["k"] as? String, let date = HealthUI.date(key),
              let kg = HealthUI.value(raw["kg"]), kg > 0, kg <= 400 else { return nil }
        self.key = key; self.date = date; self.kg = kg
    }
}

private struct HealthTrainingSession: Identifiable {
    let id: String
    let type: String
    let minutes: Double
    let distance: Double?
    let energy: Double?
    let startAt: String?
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String,
              let minutes = HealthUI.value(raw["durationMinutes"]) else { return nil }
        self.id = id; self.type = type; self.minutes = minutes
        distance = HealthUI.value(raw["distanceKm"]); energy = HealthUI.value(raw["energyKcal"])
        startAt = raw["startAt"] as? String
    }
}

enum HealthUI {
    static func value(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func number(_ value: Any?) -> String {
        guard let value = self.value(value) else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
    static func input(_ value: Any?) -> String {
        guard let value = self.value(value) else { return "" }
        return value.rounded() == value ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) : String(value)
    }
    static func flag(_ value: [String: Any], _ key: String) -> Bool { value[key] as? Bool ?? false }
    static func day(_ snapshot: [String: Any], _ category: String, _ key: String) -> [String: Any]? {
        (snapshot[category] as? [String: Any])?[key] as? [String: Any]
    }
    static func key(_ date: Date) -> String {
        let formatter = dayFormatter(); return formatter.string(from: date)
    }
    static func date(_ key: String) -> Date? {
        guard key.count == 10 else { return nil }
        let formatter = dayFormatter()
        guard let value = formatter.date(from: key), formatter.string(from: value) == key else { return nil }
        return value
    }
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter
    }
    static func instant(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: raw)
    }
    static func timestamp(_ value: Any?) -> String {
        guard let date = instant(value) else { return "时间未提供" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    static func duration(_ minutes: Double) -> String {
        let total = Int(max(0, minutes).rounded())
        return total >= 60 ? "\(total / 60) 小时 \(total % 60) 分" : "\(total) 分钟"
    }
    static func source(_ value: [String: Any]?) -> String {
        switch value?["source"] as? String {
        case "health-json": return "健康导入"
        case "mixed": return "导入后手动修正"
        default: return "手动记录"
        }
    }
    static func latestWeight(_ snapshot: [String: Any], through key: String) -> (String?, Double?) {
        let weights = snapshot["weight"] as? [String: Any] ?? [:]
        let dates = weights.keys.filter { date($0) != nil && $0 <= key && (value(weights[$0]) ?? 0) > 0 }.sorted()
        if let latest = dates.last { return (latest, value(weights[latest])) }
        let body = snapshot["body"] as? [String: Any]
        let fallback = value(body?["weightKg"])
        return (nil, fallback.flatMap { $0 > 0 ? $0 : nil })
    }
    static func requiredNumber(_ text: String, label: String) throws -> Double {
        guard let value = try NativeValues.decimal(text, name: label) else {
            throw NativeFailure("invalid_number", "请填写" + label + "。")
        }
        return value
    }
    static func sleepInput(hours: String, minutes: String, includesTimes: Bool, start: Date, end: Date) throws -> [String: Any] {
        let h = try requiredNumber(hours, label: "睡眠小时"), m = try requiredNumber(minutes, label: "睡眠分钟")
        guard h.rounded() == h, m.rounded() == m, h * 60 + m <= 1440, m <= 59 else {
            throw NativeFailure("invalid_sleep", "小时和分钟须为整数，分钟为 0–59，实际睡眠不超过 24 小时。")
        }
        var input: [String: Any] = ["asleepMinutes": h * 60 + m]
        if includesTimes {
            // Preserve the selected local day in the serialized offset, rather than
            // relabelling a morning wake-up as the previous UTC day.
            let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime]
            input["startAt"] = formatter.string(from: start); input["endAt"] = formatter.string(from: end)
        }
        return input
    }
}
