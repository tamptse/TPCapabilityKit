import Testing
import Foundation
@testable import TPCapabilityKit

func makeStoreWithCap(
    _ caps: Set<Capability> = [.heavyTask],
    configuration: TaskScheduler.Configuration = .init(),
    deterministic: Bool = false,
    prefix: String = "Fixture"
) -> (store: DynamicStore, pluginId: String) {
    let store = DynamicStore(configuration: configuration)
    if deterministic {
        store.schedulingGenerations.enableDeterministicTime(owner: store)
    }
    let pluginId = "\(prefix)_\(UUID().uuidString)"
    if !caps.isEmpty {
        store.registerCapability(for: pluginId, capabilities: caps)
    }
    return (store, pluginId)
}

func makeScheduler(
    store: DynamicStore,
    configuration: TaskScheduler.Configuration = .init(),
    clock: Clock? = nil
) -> TaskScheduler {
    TaskScheduler(
        store: store,
        configuration: configuration,
        clock: clock ?? .live,
        concurrencyController: ConcurrencyController(
            maxPerCapability: configuration.maxPerCapability,
            maxGlobal: configuration.maxGlobal
        )
    )
}

func makeDeterministicClock() -> Clock {
    let clock = Clock()
    clock.enableDeterministic()
    return clock
}

actor Probe {
    var count = 0
    var current = 0
    var maxSeen = 0
    var values: [String] = []
    var intValues: [Int] = []
    var states: [Lease.State] = []
    var lastState: Lease.State?
    var lastLease: Lease?
    var expiredId: String?

    func enter() {
        current += 1
        maxSeen = max(maxSeen, current)
    }

    func exit() {
        current -= 1
    }

    func inc() {
        count += 1
    }

    func next() -> Int {
        count += 1
        return count
    }

    func append(_ value: String) {
        values.append(value)
    }

    func append(_ value: Int) {
        intValues.append(value)
    }

    func record(_ lease: Lease) {
        count += 1
        states.append(lease.state)
        lastState = lease.state
        lastLease = lease
        if lease.state == .expired {
            expiredId = lease.task.id
        }
    }
}

struct AsyncGate: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream { break }
    }

    func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
        for await _ in stream {
            if await predicate() { break }
        }
    }

    func finish() {
        continuation.finish()
    }
}
