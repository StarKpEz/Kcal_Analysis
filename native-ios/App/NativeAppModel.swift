import Combine
import Foundation

/// One observable owner for both tabs. Views never write snapshots themselves.
@MainActor
final class NativeAppModel: ObservableObject {
    @Published private(set) var snapshot: [String: Any] = [:]
    @Published var selectedDate = Date()
    @Published var error: String?
    // Root navigation updates this before any automatic HealthKit result may save.
    var canAutomaticallySyncHealth = false
    private var domain: NativeDomain?

    init(store: SnapshotStore = SnapshotStore()) {
        do {
            let domain = try NativeDomain(store: store)
            self.domain = domain
            snapshot = domain.snapshot
            error = domain.storageIssue
        } catch { self.error = error.localizedDescription }
    }

    var dayKey: String { Self.dayKey(selectedDate) }
    var isReadOnly: Bool { domain?.readOnly ?? true }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    func query(_ operation: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        guard let domain else { throw NativeFailure("domain_unavailable", error ?? "无法读取本地记录。") }
        do { return try domain.query(operation, payload: payload) }
        catch { self.error = error.localizedDescription; throw error }
    }

    @discardableResult
    func mutate(_ operation: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        guard let domain else { throw NativeFailure("domain_unavailable", error ?? "无法保存本地记录。") }
        do {
            let result = try domain.mutate(operation, payload: payload)
            snapshot = domain.snapshot
            error = domain.storageIssue
            return result
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func shiftDate(_ days: Int) {
        if let date = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) { selectedDate = date }
    }
}

enum NativeValues {
    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    static func display(_ value: Any?, digits: Int = 0) -> String {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return "—" }
        return number.doubleValue.formatted(.number.precision(.fractionLength(0...digits)))
    }
    static func decimal(_ raw: String, name: String, optional: Bool = false) throws -> Double? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty && optional { return nil }
        guard let value = Double(raw.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else {
            throw NativeFailure("invalid_number", "请填写有效的\(name)。")
        }
        return value
    }
}
