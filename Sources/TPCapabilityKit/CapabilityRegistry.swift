import Combine
import Foundation

/// Registry half of the Store: plugin-to-capabilities mapping, reverse index,
/// per-capability subjects, and whole-snapshot subject.
///
/// Owns its own lock behind one mutate-and-notify seam: `register` and
/// `unregister` collect the mutation under lock and deliver per-Capability
/// notices before the whole-snapshot publish after unlock, so sinks never
/// run under lock and reentrant queries stay safe. No caller holds the Store
/// lock across a registry call. Per-Capability subjects are retained after
/// removal (emitting `false`) so a later creation reuses the same subject
/// instead of leaving two subjects diverging.
final class CapabilityRegistry: @unchecked Sendable {
    typealias PendingNotification = (subject: CurrentValueSubject<Bool, Never>, value: Bool)
    typealias MutationResult = (snapshot: [String: Set<Capability>], notifications: [PendingNotification])

    private let lock = NSLock()
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
            if let subject = capabilitySubjects[cap] {
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
        let mutation: MutationResult = lock.withLock {
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
        emit(mutation)
        return mutation
    }

    func unregister(for pluginId: String) -> MutationResult {
        let mutation: MutationResult = lock.withLock {
            var pending: [PendingNotification] = []
            removeCapabilities(for: pluginId, pending: &pending)

            capabilities.removeValue(forKey: pluginId)
            return (capabilities, pending)
        }
        emit(mutation)
        return mutation
    }

    func query(_ capability: Capability) -> Bool {
        lock.withLock {
            capabilityIndex[capability]?.isEmpty == false
        }
    }

    func queryCapabilities(for pluginId: String) -> Set<Capability> {
        lock.withLock {
            capabilities[pluginId] ?? []
        }
    }

    func queryAll() -> [String: Set<Capability>] {
        lock.withLock { capabilities }
    }

    func observe(_ capability: Capability) -> AnyPublisher<Bool, Never> {
        lock.withLock {
            if let existing = capabilitySubjects[capability] {
                return existing.eraseToAnyPublisher()
            }
            let initialValue = capabilityIndex[capability]?.isEmpty == false
            let subject = CurrentValueSubject<Bool, Never>(initialValue)
            capabilitySubjects[capability] = subject
            return subject.eraseToAnyPublisher()
        }
    }

    func observeAll() -> AnyPublisher<[String: Set<Capability>], Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    private func publish(snapshot: [String: Set<Capability>]) {
        snapshotSubject.send(snapshot)
    }

    private func emit(_ mutation: MutationResult) {
        for (subject, value) in mutation.notifications {
            subject.send(value)
        }
        publish(snapshot: mutation.snapshot)
    }
}
