import Combine
import Foundation

/// State storage behind the Store seam.
/// Typed edge: wrong-typed reads as absent; removals complete; never emits nil.
/// Writers get-or-create on update; observation alone never creates; removal
/// completes detached subscribers and the next update creates a fresh subject.
/// Empty plugin identifiers are rejected here: writes and removals are no-ops,
/// reads return nil, observations return an immediately-completed publisher.
final class StoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var subjects: [String: CurrentValueSubject<Any?, Never>] = [:]
    private var waiters: [String: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]] = [:]

    // Creation rendezvous: lookup-before-park lands racing subscribes on
    // existing; insert-before-drain parks racing subscribes before the drain
    // copy; drain resolution emits adjacent to value publish after unlock.
    // Removal stays out of band, never touching the waiter table.
    // `Deferred` re-runs lookup so a subscribe-racing-create never parks stale.

    // Drain emits after unlock beside the value publish.
    private func getOrCreateSubject(
        pluginId: String
    ) -> (subject: CurrentValueSubject<Any?, Never>, drain: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]) {
        lock.withLock {
            if let existing = subjects[pluginId] {
                return (existing, [])
            }
            let created = CurrentValueSubject<Any?, Never>(nil)
            subjects[pluginId] = created
            let drain = waiters.removeValue(forKey: pluginId) ?? []
            return (created, drain)
        }
    }

    // Lookup-or-park holds one lock acquisition so a racing writer cannot
    // strand a waiter.
    private func awaitCreationPublisher(
        pluginId: String
    ) -> AnyPublisher<CurrentValueSubject<Any?, Never>, Never> {
        enum Decision {
            case hit(CurrentValueSubject<Any?, Never>)
            case parked(PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>)
        }
        let decision: Decision = lock.withLock {
            if let existing = subjects[pluginId] {
                return .hit(existing)
            }
            let waiter = PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>()
            waiters[pluginId, default: []].append(waiter)
            return .parked(waiter)
        }
        switch decision {
        case .hit(let existing):
            return Just(existing).eraseToAnyPublisher()
        case .parked(let waiter):
            return waiter
                .handleEvents(receiveCancel: { [weak self, weak waiter] in
                    guard let self, let waiter else { return }
                    self.lock.withLock {
                        self.removeWaiterLocked(pluginId: pluginId, waiter: waiter)
                    }
                })
                .eraseToAnyPublisher()
        }
    }

    private func removeWaiterLocked(
        pluginId: String,
        waiter: PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>
    ) {
        guard var list = waiters[pluginId] else { return }
        list.removeAll(where: { $0 === waiter })
        if list.isEmpty {
            waiters.removeValue(forKey: pluginId)
        } else {
            waiters[pluginId] = list
        }
    }

    private func notifyDrain(
        waiters drain: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>],
        subject: CurrentValueSubject<Any?, Never>
    ) {
        for waiter in drain {
            waiter.send(subject)
            waiter.send(completion: .finished)
        }
    }

    private static func coerce<T>(_ value: Any?, to type: T.Type) -> T? {
        value as? T
    }

    func update<T>(pluginId: String, newState: T) {
        guard !pluginId.isEmpty else {
            #if DEBUG
            print("[DynamicStore] Error: Plugin ID cannot be empty")
            #endif
            return
        }
        let (subject, drain) = getOrCreateSubject(pluginId: pluginId)
        notifyDrain(waiters: drain, subject: subject)
        subject.send(newState)
    }

    /// Typed edge: wrong-typed reads as absent.
    func get<T>(pluginId: String, type: T.Type) -> T? {
        guard !pluginId.isEmpty else {
            #if DEBUG
            print("[DynamicStore] Error: Plugin ID cannot be empty")
            #endif
            return nil
        }
        return lock.withLock {
            guard let subject = subjects[pluginId] else {
                #if DEBUG
                print("[DynamicStore] Warning: getState called for non-existent plugin '\(pluginId)'")
                #endif
                return nil
            }
            guard let value = Self.coerce(subject.value, to: type) else {
                #if DEBUG
                print("[DynamicStore] Warning: Type mismatch for plugin '\(pluginId)': expected \(T.self)")
                #endif
                return nil
            }
            return value
        }
    }

    func remove(pluginId: String) {
        guard !pluginId.isEmpty else {
            #if DEBUG
            print("[DynamicStore] Error: Plugin ID cannot be empty")
            #endif
            return
        }
        let subject: CurrentValueSubject<Any?, Never>? = lock.withLock {
            subjects.removeValue(forKey: pluginId)
        }
        subject?.send(completion: .finished)
    }

    /// Typed edge: wrong-typed reads as absent; removals complete; never emits nil.
    func observe<T>(pluginId: String, type: T.Type) -> AnyPublisher<T, Never> {
        guard !pluginId.isEmpty else {
            #if DEBUG
            print("[DynamicStore] Error: Plugin ID cannot be empty")
            #endif
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }
        return Deferred { [weak self] () -> AnyPublisher<T, Never> in
            guard let self else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            return self.awaitCreationPublisher(pluginId: pluginId)
                .map { $0.compactMap { Self.coerce($0, to: type) }.eraseToAnyPublisher() }
                .switchToLatest()
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
}
