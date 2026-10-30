import SwiftUI

@MainActor
struct NativeRootView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var autoSync: NativeHealthAutoSyncModel
    @State private var tab = "diet"
    @State private var sheet: RootSheet?
    @State private var dietVisible = false
    @State private var healthVisible = false
    @State private var recorderPresented = false
    private let preferences: UserDefaults?

    init(model: NativeAppModel, preferences: UserDefaults? = .standard) {
        self.model = model
        self.preferences = preferences
        _autoSync = StateObject(wrappedValue: NativeHealthAutoSyncModel(
            defaults: preferences,
            canApply: { model.canAutomaticallySyncHealth && !model.isReadOnly },
            prepareReview: { result, from, through in
                let payload: [String: Any] = ["nativeResult": result, "from": from, "through": through, "automatic": true]
                let preview = try model.query("previewHealth", payload: payload)
                return NativeHealthAutomaticReview(updates: Int(NativeValues.number(preview["updates"])),
                    conflicts: Int(NativeValues.number(preview["conflicts"]))) {
                    let saved = try model.mutate("importHealth", payload: payload)
                    return "自动刷新已保存 \(Int(NativeValues.number(saved["updates"]))) 项日记录。"
                }
            }))
    }

    private enum RootSheet: String, Identifiable {
        case settings, sync, healthImport
        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                NativeDietView(model: model, onRecorderPresented: { presented in
                    recorderPresented = presented
                    updateAutomaticRefresh()
                })
                    .onAppear { dietVisible = true; updateAutomaticRefresh() }
                    .onDisappear { dietVisible = false; updateAutomaticRefresh() }
                    .toolbar { settingsButton }
            }
            .tabItem { Label("饮食", systemImage: "fork.knife") }
            .tag("diet")
            NavigationStack {
                HealthDashboard(model: model, onSync: { present(.sync) }, onImport: { present(.healthImport) })
                    .onAppear { healthVisible = true; updateAutomaticRefresh() }
                    .onDisappear { healthVisible = false; updateAutomaticRefresh() }
                    .toolbar { settingsButton }
            }
            .tabItem { Label("健康", systemImage: "heart") }
            .tag("health")
        }
        // System TabView supplies Liquid Glass on iOS 26 and adapts to the user's
        // transparency/contrast/motion settings. Do not overlay another glass capsule.
        .tint(.blue)
        .onChange(of: scenePhase) { _, _ in updateAutomaticRefresh() }
        .onChange(of: tab) { _, _ in updateAutomaticRefresh() }
        .onChange(of: sheet) { _, _ in updateAutomaticRefresh() }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .settings: NavigationStack { NativeSettingsView(model: model) }
            case .healthImport:
                NavigationStack {
                    NativeImportView(model: model, kind: .health)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } }
                }
            case .sync:
                NativeSyncContainer(appModel: model, preferences: preferences, automaticStatus: autoSync.errorText ?? autoSync.message)
            }
        }
    }

    @ToolbarContentBuilder private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("设置", systemImage: "gearshape") { present(.settings) }
                .accessibilityIdentifier("open-settings")
        }
    }

    private func present(_ destination: RootSheet) {
        model.canAutomaticallySyncHealth = false
        autoSync.cancel()
        sheet = destination
    }

    private func updateAutomaticRefresh() {
        let allowed = scenePhase == .active && sheet == nil && !recorderPresented
            && (tab == "diet" ? dietVisible : healthVisible)
        model.canAutomaticallySyncHealth = allowed
        if allowed { autoSync.refreshIfEnabled(allowed: true) }
        else { autoSync.cancel() }
    }
}

@MainActor
struct NativeSyncContainer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: NativeHealthSyncModel
    let automaticStatus: String?
    init(appModel: NativeAppModel, preferences: UserDefaults? = .standard, automaticStatus: String? = nil) {
        self.automaticStatus = automaticStatus
        _model = StateObject(wrappedValue: NativeHealthSyncModel(
            storageIssue: appModel.isReadOnly ? (appModel.error ?? "本地记录处于只读保护状态。") : nil,
            defaults: preferences,
            prepareReview: { result, from, through in
                let payload: [String: Any] = ["nativeResult": result, "from": from, "through": through]
                let preview = try appModel.query("previewHealth", payload: payload)
                let details = (preview["details"] as? [String] ?? []) + (preview["notes"] as? [String] ?? [])
                return NativeHealthReview(title: preview["summary"] as? String ?? "检查健康记录",
                    details: details, canCommit: NativeValues.number(preview["updates"]) > 0) {
                    let saved = try appModel.mutate("importHealth", payload: payload)
                    return "已在本机保存 \(Int(NativeValues.number(saved["updates"]))) 项日记录。"
                }
            }))
    }
    var body: some View {
        NavigationStack { NativeHealthSyncView(model: model, automaticStatus: automaticStatus, onClose: { dismiss() }) }
    }
}

@MainActor
struct NativeDateHeader: View {
    @ObservedObject var model: NativeAppModel
    @State private var calendarOpen = false
    var body: some View {
        HStack(spacing: 12) {
            Button("前一天", systemImage: "chevron.left") { model.shiftDate(-1) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            Spacer(minLength: 0)
            Button { calendarOpen = true } label: {
                VStack(spacing: 4) {
                    Text(model.selectedDate, format: .dateTime.month(.wide).day()).font(.headline)
                    Text(model.selectedDate, format: .dateTime.year().weekday(.wide)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            .accessibilityLabel("记录日期，\(model.dayKey)")
            .accessibilityIdentifier("record-date")
            Spacer(minLength: 0)
            Button("后一天", systemImage: "chevron.right") { model.shiftDate(1) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $calendarOpen) {
            NavigationStack {
                ScrollView {
                    DatePicker("记录日期", selection: $model.selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                    Button("回到今天") { model.selectedDate = Date(); calendarOpen = false }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                .navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { calendarOpen = false } } }
            }
        }
    }
}

struct NativeInlineError: View {
    let message: String
    var body: some View {
        Label { Text(message).fixedSize(horizontal: false, vertical: true) }
            icon: { Image(systemName: "exclamationmark.circle") }
            .foregroundStyle(.red).font(.callout).textSelection(.enabled)
            .accessibilityElement(children: .combine)
    }
}

struct NativeNumberField: View {
    let title: String
    @Binding var text: String
    var unit: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                TextField(title, text: $text).keyboardType(.decimalPad)
                    .accessibilityLabel(title).textFieldStyle(.plain)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }.frame(minHeight: 44)
        }.padding(.vertical, 4)
    }
}
