import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Store Determinism Tests")
struct StoreDeterminismTests {
    @Test("timeout pins expired via lease state with virtual time")
    func timeoutPinsExpiredWithVirtualTime() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let cap = Capability.custom("deterministicTimeout_\(UUID().uuidString)")

        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0),
            task: {},
            completion: { _ in done.continuation.yield() }
        )

        await store.advanceTime(by: 5.0)
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("execution expiry pins expired with virtual time while blocked")
    func executionExpiryWithVirtualTime() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let pluginId = "DeterministicExec_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0),
            task: {
                started.continuation.yield()
                for await _ in release.stream { break }
            },
            completion: { _ in done.continuation.yield() }
        )

        for await _ in started.stream { break }
        await store.advanceTime(by: 5.0)
        for await _ in done.stream { break }
        release.continuation.finish()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("priority order pins high-before-low through Store counts and lease state")
    func priorityOrderHighBeforeLow() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 10, maxGlobal: 1))
        store.enableDeterministicTime()
        let pluginId = "DeterministicPriority_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        actor Order {
            var values: [String] = []
            func append(_ value: String) { values.append(value) }
        }
        let order = Order()
        actor Completions {
            var count = 0
            func inc() { count += 1 }
        }
        let completions = Completions()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let drained = AsyncStream<Void>.makeStream()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
            task: {
                started.continuation.yield()
                for await _ in release.stream { break }
            },
            completion: { _ in
                Task {
                    await completions.inc()
                    drained.continuation.yield()
                }
            }
        )
        for await _ in started.stream { break }

        let low = TaskDescriptor(requiredCapabilities: [.heavyTask], priority: .low, timeout: 30.0)
        let high = TaskDescriptor(requiredCapabilities: [.heavyTask], priority: .high, timeout: 30.0)
        for descriptor in [high, low] {
            store.scheduleTask(descriptor, task: {
                await order.append(descriptor.priority == .high ? "high" : "low")
            }, completion: { _ in
                Task {
                    await completions.inc()
                    drained.continuation.yield()
                }
            })
        }

        release.continuation.finish()
        for await _ in drained.stream {
            if await completions.count == 3 { break }
        }

        #expect(await order.values == ["high", "low"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("slot serialization pins single active through Store counts and lease state")
    func slotSerializationSingleActive() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10))
        store.enableDeterministicTime()
        let pluginId = "DeterministicSlot_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        actor Probe {
            var current = 0
            var maxSeen = 0
            func enter() {
                current += 1
                maxSeen = max(maxSeen, current)
            }
            func exit() { current -= 1 }
        }
        let probe = Probe()
        actor Completions {
            var count = 0
            func inc() { count += 1 }
        }
        let completions = Completions()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let drained = AsyncStream<Void>.makeStream()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
            task: {
                await probe.enter()
                started.continuation.yield()
                for await _ in release.stream { break }
                await probe.exit()
            },
            completion: { _ in
                Task {
                    await completions.inc()
                    drained.continuation.yield()
                }
            }
        )
        for await _ in started.stream { break }
        #expect(store.activeTaskCount == 1)

        let totalContenders = 3
        for _ in 0..<totalContenders {
            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
                task: {
                    await probe.enter()
                    await Task.yield()
                    await Task.yield()
                    await probe.exit()
                },
                completion: { _ in
                    Task {
                        await completions.inc()
                        drained.continuation.yield()
                    }
                }
            )
        }

        release.continuation.finish()
        for await _ in drained.stream {
            if await completions.count == totalContenders + 1 { break }
        }

        #expect(await probe.maxSeen <= 1)
        #expect(await completions.count == totalContenders + 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel pins expired through Store lease state and counts")
    func cancelPinsExpiredThroughStore() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let cap = Capability.custom("deterministicCancel_\(UUID().uuidString)")

        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in done.continuation.yield() }
        )
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: lease.task.id)
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("virtual time preserved across reconfigure generations")
    func virtualTimePreservedAcrossGenerations() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let cap = Capability.custom("deterministicGen_\(UUID().uuidString)")

        let done = AsyncStream<Void>.makeStream()
        actor Completions {
            var count = 0
            func inc() { count += 1 }
        }
        let completions = Completions()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0),
            task: {},
            completion: { _ in
                Task {
                    await completions.inc()
                    done.continuation.yield()
                }
            }
        )
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 20))
        #expect(store.pendingTaskCount == 1)

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0),
            task: {},
            completion: { _ in
                Task {
                    await completions.inc()
                    done.continuation.yield()
                }
            }
        )
        #expect(store.pendingTaskCount == 2)

        await store.waitForDeterministicWaiters(count: 2)
        await store.advanceTime(by: 5.0)
        for await _ in done.stream {
            if await completions.count == 2 { break }
        }

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.generationCount == 1)
    }
}
