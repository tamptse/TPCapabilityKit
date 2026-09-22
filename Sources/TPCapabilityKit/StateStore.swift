import Combine
import Foundation

/// State half of the Store: per-plugin subjects keyed by plugin id.
///
/// Holds no lock of its own: every call that touches mutable state must happen
/// while holding the Store lock, exactly as the fields were guarded before
/// extraction. Subject `send` / subscription are safe without holding the
/// Store lock, so creation is collected under lock and sends happen after
/// unlock, keeping sink-query callbacks safe.
///
/// Removal detaches the subject: the Store sends `nil` after unlock (filtered
/// by typed observers via `compactMap`), and the next update creates a fresh
/// subject for new subscribers.
final class StateStore: @unchecked Sendable {
    private var subjects: [String: CurrentValueSubject<Any?, Never>] = [:]

    func ensureSubject(for pluginId: String) -> CurrentValueSubject<Any?, Never> {
        if let existing = subjects[pluginId] {
            return existing
        }
        let subject = CurrentValueSubject<Any?, Never>(nil)
        subjects[pluginId] = subject
        return subject
    }

    func subject(for pluginId: String) -> CurrentValueSubject<Any?, Never>? {
        subjects[pluginId]
    }

    func removeSubject(for pluginId: String) -> CurrentValueSubject<Any?, Never>? {
        subjects.removeValue(forKey: pluginId)
    }
}
