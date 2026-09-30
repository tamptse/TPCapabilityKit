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
    private enum Rendezvous {
        case hit(CurrentValueSubject<Any?, Never>)
        case created(
            CurrentValueSubject<Any?, Never>,
            drain: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]
        )
        case parked(PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>)
    }

    private func rendezvousLocked(
        pluginId: String,
        createIfMissing: Bool
    ) -> Rendezvous {
        if let existing = subjects[pluginId] {
            return .hit(existing)
        }
        if createIfMissing {
            let created = CurrentValueSubject<Any?, Never>(nil)
            subjects[pluginId] = created
            let drain = waiters.removeValue(forKey: pluginId) ?? []
            return .created(created, drain: drain)
        }
        let waiter = PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>()
        waiters[pluginId, default: []].append(waiter)
        return .parked(waiter)
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

    private func lookupOrAwaitCreation(
        pluginId: String,
        createIfMissing: Bool
    ) -> AnyPublisher<CurrentValueSubject<Any?, Never>, Never> {
        let outcome: Rendezvous = lock.withLock {
            rendezvousLocked(pluginId: pluginId, createIfMissing: createIfMissing)
        }
        switch outcome {
        case .hit(let subject):
            return Just(subject).eraseToAnyPublisher()
        case .created(let subject, let drain):
            notifyDrain(waiters: drain, subject: subject)
            return Just(subject).eraseToAnyPublisher()
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

    func update<T>(pluginId: String, newState: T) {
        guard validatePluginId(pluginId) else { return }
        let outcome: Rendezvous = lock.withLock {
            rendezvousLocked(pluginId: pluginId, createIfMissing: true)
        }
        switch outcome {
        case .hit(let subject):
            subject.send(newState)
        case .created(let subject, let drain):
            notifyDrain(waiters: drain, subject: subject)
            subject.send(newState)
        case .parked:
            preconditionFailure("rendezvous with createIfMissing must never park")
        }
    }

    /// Typed edge: wrong-typed reads as absent.
    func get<T>(pluginId: String, type: T.Type) -> T? {
        guard validatePluginId(pluginId) else { return nil }
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
        guard validatePluginId(pluginId) else { return }
        let subject: CurrentValueSubject<Any?, Never>? = lock.withLock {
            subjects.removeValue(forKey: pluginId)
        }
        subject?.send(completion: .finished)
    }

    /// Typed edge: wrong-typed reads as absent; removals complete; never emits nil.
    func observe<T>(pluginId: String, type: T.Type) -> AnyPublisher<T, Never> {
        guard validatePluginId(pluginId) else {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }
        return Deferred { [weak self] () -> AnyPublisher<T, Never> in
            guard let self else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            return self.lookupOrAwaitCreation(pluginId: pluginId, createIfMissing: false)
                .map { $0.compactMap { Self.coerce($0, to: type) }.eraseToAnyPublisher() }
                .switchToLatest()
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
}
