import Combine
import Foundation

/// Registry half of the Store: plugin-to-capabilities mapping, reverse index,
/// per-capability subjects, and whole-snapshot subject.
///
/// Holds no lock of its own: every call that touches mutable state must happen
/// while holding the Store lock, exactly as the fields were guarded before
/// extraction. The snapshot subject reference itself is stable (`let`) and its
/// `send` / subscription are safe without holding the Store lock. Mutation is
/// collected under lock and Combine sends happen after unlock, so sink-query
/// callbacks stay safe.
final class CapabilityRegistry: @unchecked Sendable {
    typealias PendingNotification = (subject: CurrentValueSubject<Bool, Never>, value: Bool)
    typealias MutationResult = (snapshot: [String: Set<Capability>], notifications: [PendingNotification])

    private var capabilities: [String: Set<Capability>] = [:]
    private var capabilityIndex: [Capability: Set<String>] = [:]
    private var capabilitySubjects: [Capability: CurrentValueSubject<Bool, Never>] = [:]
    private let snapshotSubject = CurrentValueSubject<[String: Set<Capability>], Never>([:])

    private func cleanupCapabilityIfEmpty(
        _ cap: Capability,
        pending: inout [PendingNotification]
    ) {
        if capabilityIndex[cap]?.isEmpty == true {
            capabilityIndex.removeValue(forKey: cap)
            if let subject = capabilitySubjects.removeValue(forKey: cap) {
                pending.append((subject, false))
            }
        }
    }

    private func removeCapabilities(
        for pluginId: String,
        pending: inout [PendingNotification]
    ) {
        guard let oldCapabilities = capabilities[pluginId] else { return }
        for cap in oldCapabilities {
            capabilityIndex[cap]?.remove(pluginId)
            cleanupCapabilityIfEmpty(cap, pending: &pending)
        }
    }

    func register(for pluginId: String, capabilities caps: Set<Capability>) -> MutationResult {
        var pending: [PendingNotification] = []
        removeCapabilities(for: pluginId, pending: &pending)

        capabilities[pluginId] = caps
        for cap in caps {
            capabilityIndex[cap, default: []].insert(pluginId)
            if let subject = capabilitySubjects[cap] {
                pending.append((subject, true))
            }
        }

        return (capabilities, pending)
    }

    func unregister(for pluginId: String) -> MutationResult {
        var pending: [PendingNotification] = []
        removeCapabilities(for: pluginId, pending: &pending)

        capabilities.removeValue(forKey: pluginId)
        return (capabilities, pending)
    }

    func query(_ capability: Capability) -> Bool {
        capabilityIndex[capability]?.isEmpty == false
    }

    func queryCapabilities(for pluginId: String) -> Set<Capability> {
        capabilities[pluginId] ?? []
    }

    func queryAll() -> [String: Set<Capability>] {
        capabilities
    }

    func observe(_ capability: Capability) -> AnyPublisher<Bool, Never> {
        if let existing = capabilitySubjects[capability] {
            return existing.eraseToAnyPublisher()
        }
        let initialValue = capabilityIndex[capability]?.isEmpty == false
        let subject = CurrentValueSubject<Bool, Never>(initialValue)
        capabilitySubjects[capability] = subject
        return subject.eraseToAnyPublisher()
    }

    func observeAll() -> AnyPublisher<[String: Set<Capability>], Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    func publish(snapshot: [String: Set<Capability>]) {
        snapshotSubject.send(snapshot)
    }
}
