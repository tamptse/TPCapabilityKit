import Combine
import Foundation

/// State storage behind the Store seam.
/// Writers get-or-create on update; observation alone never creates; removal
/// completes detached subscribers and the next update creates a fresh subject.
/// Empty plugin identifiers are rejected here: writes and removals are no-ops,
/// reads return nil, observations return an immediately-completed publisher.
final class StoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var subjects: [String: CurrentValueSubject<Any?, Never>] = [:]
    private var waiters: [String: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]] = [:]

    // State creation rendezvous: single lookup-or-await-creation transition.
    // Late-subscriber proof in one place: lookup-before-park under one lock
    // means a create racing a subscribe lands on existing instead of parking
    // stale; insert-before-drain under one lock means a subscribe racing a
    // create parks before the drain copies it, so no parker is skipped;
    // waiter resolution emits adjacent to the subject value publish after
    // unlock, so no waiter sleeps through its subject; `Deferred` re-runs
    // lookup so a subscribe-racing-create lands on existing instead of
    // parking stale.
    // Locked work is index read-or-insert plus waiter park-or-drain-list copy
    // only; both publishes emit after unlock. Removal stays out of band: it
    // deletes the index entry and completes the detached subject, never
    // touches the waiter table.
    // Single locked subject-creation step shared by the creation branch
    // above and `update` below, so index insert plus waiter drain-list copy
    // live in exactly one place. Call only with `lock` held.
    private func insertFreshSubject(
        pluginId: String
    ) -> (subject: CurrentValueSubject<Any?, Never>, drain: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]) {
        let created = CurrentValueSubject<Any?, Never>(nil)
        subjects[pluginId] = created
        let drain = waiters.removeValue(forKey: pluginId) ?? []
        return (created, drain)
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

    // Single coercion policy for the typed edge: a wrong-typed value reads as absent.
    private static func coerce<T>(_ value: Any?, to type: T.Type) -> T? {
        value as? T
    }

    private func lookupOrAwaitCreation(
        pluginId: String,
        createIfMissing: Bool
    ) -> AnyPublisher<CurrentValueSubject<Any?, Never>, Never> {
        enum Outcome {
            case hit(CurrentValueSubject<Any?, Never>)
            case created(
                CurrentValueSubject<Any?, Never>,
                drain: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]
            )
            case parked(PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>)
        }
        let outcome: Outcome = lock.withLock { () -> Outcome in
            if let existing = subjects[pluginId] {
                return .hit(existing)
            }
            if createIfMissing {
                let fresh = insertFreshSubject(pluginId: pluginId)
                return .created(fresh.subject, drain: fresh.drain)
            }
            let waiter = PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>()
            waiters[pluginId, default: []].append(waiter)
            return .parked(waiter)
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
                        if var list = self.waiters[pluginId] {
                            list.removeAll(where: { $0 === waiter })
                            if list.isEmpty {
                                self.waiters.removeValue(forKey: pluginId)
                            } else {
                                self.waiters[pluginId] = list
                            }
                        }
                    }
                })
                .eraseToAnyPublisher()
        }
    }

    func update<T>(pluginId: String, newState: T) {
        guard validatePluginId(pluginId) else { return }
        let resolved: (subject: CurrentValueSubject<Any?, Never>, drain: [PassthroughSubject<CurrentValueSubject<Any?, Never>, Never>]) = lock.withLock {
            if let existing = subjects[pluginId] {
                return (existing, [])
            }
            return insertFreshSubject(pluginId: pluginId)
        }
        notifyDrain(waiters: resolved.drain, subject: resolved.subject)
        resolved.subject.send(newState)
    }

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
