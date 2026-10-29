import Foundation
import HealthKit

protocol NativeHealthProviding {
    var isAvailable: Bool { get }
    func authorize(completion: @escaping (Result<[String: Any], Error>) -> Void)
    func sync(params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void)
}

/// Read-only adapter. Returned documents pass through the web app's existing
/// parseHealthJSON -> healthImportPlan -> one commitData transaction.
/// Never treat an empty query as proof of read permission or as a deletion.
final class HealthKitService: NativeHealthProviding {
    typealias Completion = (Result<[String: Any], Error>) -> Void
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        for id: HKQuantityTypeIdentifier in [.bodyMass, .activeEnergyBurned, .basalEnergyBurned] {
            if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        return types
    }

    func authorize(completion: @escaping Completion) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(Self.failure("当前设备无法使用 Apple 健康，请在 iPhone 上运行。")))
            return
        }
        // Empty write set is intentional: there are no HealthKit save/delete calls.
        store.requestAuthorization(toShare: [], read: readTypes) { finished, error in
            if let error = error { completion(.failure(error)); return }
            guard finished else {
                completion(.failure(Self.failure("健康读取授权请求未完成，请稍后重试。")))
                return
            }
            completion(.success([
                "requestCompleted": true,
                "readAuthorization": "notObservable",
                "notes": ["授权流程已完成；iOS 不向 App 透露各项读取是否被拒绝。无数据时请检查健康授权与设备同步。"]
            ]))
        }
    }

    func sync(params: [String: Any], completion: @escaping Completion) {
        guard let from = params["from"] as? String, let through = params["through"] as? String else {
            completion(.failure(Self.failure("请选择起止日期。")))
            return
        }
        if let value = params["sleepSource"], !(value is String), !(value is NSNull) {
            completion(.failure(Self.failure("睡眠来源参数无效。")))
            return
        }
        read(from: from, through: through, sleepSource: params["sleepSource"] as? String, completion: completion)
    }

    func read(from: String, through: String, sleepSource: String? = nil, completion: @escaping Completion) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(Self.failure("当前设备无法读取 Apple 健康。")))
            return
        }
        let context: DateContext
        do { context = try DateContext(from: from, through: through) }
        catch { completion(.failure(error)); return }

        let group = DispatchGroup()
        let state = FetchState()
        for (key, id) in [("active", HKQuantityTypeIdentifier.activeEnergyBurned), ("basal", .basalEnergyBurned)] {
            group.enter()
            queryEnergy(id, context: context) { result in
                state.update {
                    switch result {
                    case .success(let days): $0.energy[key] = days
                    case .failure(let error): $0.notes.append("\(key == "active" ? "活动" : "静息")能量读取失败：\(error.localizedDescription)。本次保留已有能量。")
                    }
                }
                group.leave()
            }
        }

        group.enter()
        querySamples(type: HKObjectType.quantityType(forIdentifier: .bodyMass), start: context.start,
                     end: context.queryEnd, strictStart: true) { result in
            state.update {
                switch result {
                case .success(let rows): $0.weights = rows.compactMap { $0 as? HKQuantitySample }
                case .failure(let error): $0.notes.append("体重读取失败：\(error.localizedDescription)。本次保留已有体重。")
                }
            }
            group.leave()
        }

        group.enter()
        querySamples(type: HKObjectType.workoutType(), start: context.start,
                     end: context.queryEnd, strictStart: true) { result in
            state.update {
                switch result {
                case .success(let rows): $0.workouts = rows.compactMap { $0 as? HKWorkout }
                case .failure(let error): $0.notes.append("训练读取失败：\(error.localizedDescription)。本次保留已有训练。")
                }
            }
            group.leave()
        }

        group.enter()
        // Include both sides of the requested archive window: otherwise a sleep
        // group cut at midnight could be incorrectly archived on the previous day.
        querySamples(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis), start: context.sleepStart,
                     end: context.sleepEnd, strictStart: false) { result in
            state.update {
                switch result {
                case .success(let rows): $0.sleep = rows.compactMap { $0 as? HKCategorySample }
                case .failure(let error): $0.notes.append("睡眠读取失败：\(error.localizedDescription)。本次保留已有睡眠。")
                }
            }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let result = self.makePayload(state.snapshot(), context: context, sleepSource: sleepSource)
            completion(.success(result))
        }
    }

    private func queryEnergy(_ id: HKQuantityTypeIdentifier, context: DateContext,
                             completion: @escaping (Result<[String: Double], Error>) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else {
            completion(.failure(Self.failure("该能量类型不可用。")))
            return
        }
        let predicate = HKQuery.predicateForSamples(withStart: context.start, end: context.queryEnd, options: [])
        // Use HealthKit's daily statistics across sources, not a sum of raw samples
        // or the shortcut's start-date/boundary approximation. Never add workouts.
        let interval = DateComponents(calendar: context.calendar, timeZone: context.calendar.timeZone, day: 1)
        let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
            options: .cumulativeSum, anchorDate: context.start, intervalComponents: interval)
        query.initialResultsHandler = { _, collection, error in
            if let error = error { completion(.failure(error)); return }
            guard let collection = collection else {
                completion(.failure(Self.failure("HealthKit 未返回能量统计。")))
                return
            }
            var days: [String: Double] = [:]
            collection.enumerateStatistics(from: context.start, to: context.queryEnd) { statistics, _ in
                let key = context.day(statistics.startDate)
                guard context.contains(key), let sum = statistics.sumQuantity() else { return }
                let value = sum.doubleValue(for: .kilocalorie())
                // nil is absent, whereas an actual zero-valued sum is a reading.
                if value.isFinite, value >= 0, value <= 50_000 { days[key] = value }
            }
            completion(.success(days))
        }
        store.execute(query)
    }

    private func querySamples(type: HKSampleType?, start: Date, end: Date, strictStart: Bool,
                              completion: @escaping (Result<[HKSample], Error>) -> Void) {
        guard let type = type else { completion(.failure(Self.failure("健康样本类型不可用。"))); return }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: strictStart ? .strictStartDate : [])
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, rows, error in
            if let error = error { completion(.failure(error)); return }
            completion(.success(rows ?? []))
        }
        store.execute(query)
    }

    private func makePayload(_ data: FetchData, context: DateContext, sleepSource: String?) -> [String: Any] {
        var days: [String: [String: Any]] = [:]
        var notes = data.notes
        func put(_ key: String, _ category: String, _ value: Any) {
            var day = days[key] ?? ["date": key]
            day[category] = value
            days[key] = day
        }

        let active = data.energy["active"] ?? [:], basal = data.energy["basal"] ?? [:]
        for date in Set(active.keys).union(basal.keys).sorted() {
            guard let a = active[date], let b = basal[date] else {
                notes.append("\(date) 缺少活动或静息统计，本次保留已有能量，不补零。")
                continue
            }
            put(date, "energy", ["active": a, "basal": b])
        }
        if active.isEmpty || basal.isEmpty {
            notes.append("部分能量没有可读数据；可能尚未同步、没有记录或未获读取权限。")
        }
        if context.contains(context.day(context.now)) {
            notes.append("今天的能量为读取时的累计值，后续同步可能继续增加。")
        }
        notes.append("能量由 HealthKit 按当地自然日统计；活动加静息，不另加训练热量。首次请与健康 App 的同日数值对照。")

        if let weights = data.weights {
            var last: [String: HKQuantitySample] = [:]
            var ambiguous = Set<String>()
            for row in weights where row.startDate < context.queryEnd && row.startDate <= context.now {
                let key = context.day(row.startDate)
                guard context.contains(key) else { continue }
                if let prior = last[key] {
                    if row.startDate == prior.startDate,
                       row.quantity.doubleValue(for: .gramUnit(with: .kilo)) != prior.quantity.doubleValue(for: .gramUnit(with: .kilo)) {
                        ambiguous.insert(key)
                    }
                    if row.startDate <= prior.startDate { continue }
                    ambiguous.remove(key)
                }
                last[key] = row
            }
            for (date, sample) in last {
                let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                guard !ambiguous.contains(date), kg.isFinite, kg >= 0.1, kg <= 400 else {
                    notes.append("\(date) 最后称重数值无效或同一时间有冲突，本次保留已有体重。")
                    continue
                }
                put(date, "weight", ["kg": kg, "measuredAt": context.timestamp(sample.startDate)])
            }
            if last.isEmpty { notes.append("范围内无可读体重，未补值；请检查记录、同步与读取权限。") }
        }

        if let workouts = data.workouts {
            var grouped: [String: [HKWorkout]] = [:]
            var seen = Set<UUID>()
            for workout in workouts where workout.startDate < context.queryEnd && workout.startDate <= context.now {
                let date = context.day(workout.startDate)
                guard context.contains(date), seen.insert(workout.uuid).inserted else { continue }
                grouped[date, default: []].append(workout)
            }
            for (date, rows) in grouped {
                guard rows.count <= 100,
                      rows.allSatisfy({ $0.duration.isFinite && $0.duration >= 6 && $0.duration <= 86_400 && $0.endDate <= context.now }),
                      rows.reduce(0.0, { $0 + $1.duration / 60 }) <= 1_440 else {
                    notes.append("\(date) 训练未结束、时长不符合协议或超过每日上限，本次保留整天训练，避免部分列表覆盖。")
                    continue
                }
                let sessions: [[String: Any]] = rows.sorted { $0.startDate < $1.startDate }.map { workout in
                    var session: [String: Any] = [
                        "id": workout.uuid.uuidString,
                        "type": Self.workoutName(workout),
                        "startAt": context.timestamp(workout.startDate),
                        // HKWorkout.duration excludes recorded pauses. Never use end-start.
                        "durationMinutes": workout.duration / 60
                    ]
                    if let distance = workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
                       distance.isFinite, distance >= 0, distance <= 10_000 {
                        session["distanceKm"] = distance
                    }
                    if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
                       let quantity = workout.statistics(for: type)?.sumQuantity() ?? workout.totalEnergyBurned {
                        let kcal = quantity.doubleValue(for: .kilocalorie())
                        if kcal.isFinite, kcal >= 0, kcal <= 50_000 { session["energyKcal"] = kcal }
                    }
                    return session
                }
                put(date, "training", sessions)
            }
            if grouped.isEmpty { notes.append("范围内无可读训练，可能没有记录或未授权；不输出空列表，不清空已有训练。") }
            notes.append("训练按开始日期归档，保留全部运动类型及稳定 UUID；跨午夜训练仍归开始日，使用实际训练时长。")
        }

        var sleepDocument: Any = NSNull()
        var sleepSources: [[String: String]] = []
        if let sleep = data.sleep {
            // A phone may contribute only inBed while a Watch provides actual
            // sleep. inBed-only sources are not competing sleep measurements.
            let groups = Dictionary(grouping: sleep, by: Self.sleepSourceID).filter {
                !Self.sleepArchiveRows($0.value, context: context).isEmpty
            }
            sleepSources = groups.keys.sorted().map { id in
                let row = groups[id]![0]
                let device = row.device?.name ?? row.device?.model ?? ""
                return ["id": id, "name": row.sourceRevision.source.name + (device.isEmpty ? "" : " · " + device)]
            }
            let selected = sleepSource.flatMap { $0.isEmpty ? nil : $0 } ?? (groups.count == 1 ? groups.keys.first : nil)
            if let selected = selected, let sourceRows = groups[selected] {
                let rows = Self.sleepArchiveRows(sourceRows, context: context)
                // No partial truncation: every day replaces that day's old category.
                if rows.count > 30_000 {
                    notes.append("睡眠样本超过 30,000 条，请缩小日期范围；本次保留已有睡眠。")
                } else if rows.contains(where: { !(0...5).contains($0.value) || $0.endDate <= $0.startDate || $0.endDate.timeIntervalSince($0.startDate) > 129_600 || $0.endDate > context.now }) {
                    notes.append("睡眠含未知分类、未结束或无效片段，本次保留已有睡眠。")
                } else if rows.contains(where: { [1, 3, 4, 5].contains($0.value) }) {
                    // Preserve categories and one source. The shared converter performs
                    // interval unions, awake/inBed exclusion, and conflict validation.
                    let samples: [[String: Any]] = rows.map { row in [
                        "kind": "sleep", "value": row.value,
                        "startAt": context.timestamp(row.startDate), "endAt": context.timestamp(row.endDate),
                        "source": String(row.sourceRevision.source.name.prefix(160))
                    ] }
                    let document: [String: Any] = [
                        "app": "kcal-health-samples", "version": 1,
                        "exportedAt": context.timestamp(context.now), "from": context.from, "through": context.through,
                        "samples": samples
                    ]
                    if let encoded = try? JSONSerialization.data(withJSONObject: document), encoded.count <= 5 * 1_024 * 1_024 {
                        sleepDocument = document
                        notes.append("睡眠仅取来源：\(rows[0].sourceRevision.source.name)。清醒与卧床不计入实际睡眠，沿用现有区间去重及醒来日期归档。")
                    } else {
                        notes.append("睡眠数据超过导入大小上限，请缩小日期范围；本次保留已有睡眠。")
                    }
                } else { notes.append("所选来源没有可读的实际睡眠片段，本次保留已有睡眠。") }
            } else if !groups.isEmpty {
                notes.append(sleepSource == nil || sleepSource == "" ? "发现多个睡眠来源，请选择一个后重新读取；本次保留已有睡眠，未混合来源。" : "所选睡眠来源在此范围没有数据，请重新选择；本次保留已有睡眠。")
            } else { notes.append("范围内无可读睡眠，可能没有记录、尚未同步或未授权；不清空已有睡眠。") }
        }

        let sortedDays = days.keys.sorted().compactMap { days[$0] }
        var daily: Any = NSNull()
        if !sortedDays.isEmpty {
            daily = ["app": "kcal-health", "version": 2, "exportedAt": context.timestamp(context.now), "days": sortedDays] as [String: Any]
        }
        notes.append("所有日期采用本次读取时的设备时区 \(context.calendar.timeZone.identifier)，跨时区旅行后请核对归档。空查询无法区分无记录与未授权，未提供的日期和类别均保留。")
        var seenNotes = Set<String>()
        return [
            "daily": daily, "sleepSamples": sleepDocument, "sleepSources": sleepSources,
            "timeZone": context.calendar.timeZone.identifier,
            "notes": notes.filter { seenNotes.insert($0).inserted }
        ]
    }

    private static func sleepSourceID(_ sample: HKCategorySample) -> String {
        // Source plus device prevents collapsing two physical watches with the same
        // application bundle. This ID stays on device and is never uploaded.
        let source = sample.sourceRevision.source
        return [source.bundleIdentifier, source.name, sample.device?.localIdentifier ?? sample.device?.name ?? ""].joined(separator: "|")
    }

    private static func sleepArchiveRows(_ rows: [HKCategorySample], context: DateContext) -> [HKCategorySample] {
        // Match the shared converter's 90-minute grouping before dropping padding.
        // Merely filtering each sample by end date would cut a midnight sleep group.
        var groups: [[HKCategorySample]] = []
        var end = Date.distantPast
        for row in rows.sorted(by: { $0.startDate < $1.startDate }) {
            if groups.isEmpty || row.startDate.timeIntervalSince(end) > 90 * 60 {
                groups.append([row]); end = row.endDate
            } else {
                groups[groups.count - 1].append(row); end = max(end, row.endDate)
            }
        }
        return groups.filter { group in
            guard let last = group.max(by: { $0.endDate < $1.endDate }) else { return false }
            return context.contains(context.day(last.endDate)) && group.contains { [1, 3, 4, 5].contains($0.value) }
        }.flatMap { $0 }
    }

    private static func workoutName(_ workout: HKWorkout) -> String {
        let indoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue
        switch workout.workoutActivityType {
        case .walking: return indoor == true ? "室内步行" : indoor == false ? "户外步行" : "步行"
        case .running: return indoor == true ? "室内跑步" : indoor == false ? "户外跑步" : "跑步"
        case .cycling: return indoor == true ? "室内骑行" : indoor == false ? "户外骑行" : "骑行"
        case .highIntensityIntervalTraining: return "HIIT"
        case .swimming:
            let location = (workout.metadata?[HKMetadataKeySwimmingLocationType] as? NSNumber)?.intValue
            if location == HKWorkoutSwimmingLocationType.pool.rawValue { return "泳池游泳" }
            if location == HKWorkoutSwimmingLocationType.openWater.rawValue { return "开放水域游泳" }
            return "游泳"
        case .traditionalStrengthTraining: return "传统力量训练"
        case .functionalStrengthTraining: return "功能性力量训练"
        case .coreTraining: return "核心训练"
        case .elliptical: return "椭圆机"
        case .stairClimbing, .stairs: return "爬楼梯"
        case .rowing: return "划船"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .pilates: return "普拉提"
        case .flexibility: return "柔韧训练"
        case .cooldown: return "整理放松"
        case .crossTraining: return "交叉训练"
        case .mixedCardio: return "混合有氧"
        case .jumpRope: return "跳绳"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .tennis: return "网球"
        case .tableTennis: return "乒乓球"
        case .boxing: return "拳击"
        case .martialArts: return "武术"
        case .taiChi: return "太极拳"
        case .dance, .cardioDance, .socialDance: return "舞蹈"
        case .other: return "其他训练"
        default: return "HealthKit 训练 \(workout.workoutActivityType.rawValue)"
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KcalAnalysis.HealthKit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private struct DateContext {
        let from: String
        let through: String
        let now: Date
        let start: Date
        let queryEnd: Date
        let sleepStart: Date
        let sleepEnd: Date
        let calendar: Calendar

        init(from: String, through: String) throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            let now = Date()
            guard from.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  through.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let start = formatter.date(from: from), let last = formatter.date(from: through),
                  formatter.string(from: start) == from, formatter.string(from: last) == through,
                  start <= last, last <= calendar.startOfDay(for: now),
                  let count = calendar.dateComponents([.day], from: start, to: last).day, count < 3_660,
                  let end = calendar.date(byAdding: .day, value: 1, to: last),
                  let sleepStart = calendar.date(byAdding: .day, value: -2, to: start),
                  let sleepEnd = calendar.date(byAdding: .day, value: 2, to: end) else {
                throw HealthKitService.failure("日期范围无效：请选择今天及以前的日期，一次最多 3,660 天。")
            }
            self.from = from; self.through = through; self.now = now
            self.start = start; self.queryEnd = min(end, now)
            self.sleepStart = sleepStart; self.sleepEnd = min(sleepEnd, now)
            self.calendar = calendar
        }

        func contains(_ key: String) -> Bool { key >= from && key <= through }
        func day(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func timestamp(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }

    private struct FetchData {
        var energy: [String: [String: Double]] = [:]
        var weights: [HKQuantitySample]?
        var workouts: [HKWorkout]?
        var sleep: [HKCategorySample]?
        var notes: [String] = []
    }
    private final class FetchState {
        private let lock = NSLock()
        private var data = FetchData()
        func update(_ block: (inout FetchData) -> Void) { lock.lock(); defer { lock.unlock() }; block(&data) }
        func snapshot() -> FetchData { lock.lock(); defer { lock.unlock() }; return data }
    }
}
