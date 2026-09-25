import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Store Determinism Tests")
struct StoreDeterminismTests {
    @Test("timeout pins expired via lease state with virtual time")
    func timeoutPinsExpiredWithVirtualTime() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let cap = Capability.custom("deterministicTimeout_\(UUID().uuidString)")

        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0),
            task: {},
            completion: { _ in done.continuation.yield() }
        )

        await store.schedulingGenerations.advanceTime(by: 5.0)
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("execution expiry pins expired with virtual time while blocked")
    func executionExpiryWithVirtualTime() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            deterministic: true,
            prefix: "DeterministicExec"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0),
            task: {
                started.signal()
                await release.wait()
            },
            completion: { _ in done.signal() }
        )

        await started.wait()
        await store.schedulingGenerations.advanceTime(by: 5.0)
        await done.wait()
        release.finish()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("priority order pins high-before-low through Store counts and lease state")
    func priorityOrderHighBeforeLow() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 10, maxGlobal: 1),
            deterministic: true,
            prefix: "DeterministicPriority"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let completions = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let drained = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
            task: {
                started.signal()
                await release.wait()
            },
            completion: { _ in
                Task {
                    await completions.inc()
                    drained.signal()
                }
            }
        )
        await started.wait()

        let low = TaskDescriptor(requiredCapabilities: [.heavyTask], priority: .low, timeout: 30.0)
        let high = TaskDescriptor(requiredCapabilities: [.heavyTask], priority: .high, timeout: 30.0)
        for descriptor in [high, low] {
            store.scheduleTask(descriptor, task: {
                await order.append(descriptor.priority == .high ? "high" : "low")
            }, completion: { _ in
                Task {
                    await completions.inc()
                    drained.signal()
                }
            })
        }

        release.finish()
        for await _ in drained.stream {
            if await completions.count == 3 { break }
        }

        #expect(await order.values == ["high", "low"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("slot serialization pins single active through Store counts and lease state")
    func slotSerializationSingleActive() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10),
            deterministic: true,
            prefix: "DeterministicSlot"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let probe = Probe()
        let completions = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let drained = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
            task: {
                await probe.enter()
                started.signal()
                await release.wait()
                await probe.exit()
            },
            completion: { _ in
                Task {
                    await completions.inc()
                    drained.signal()
                }
            }
        )
        await started.wait()
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
                        drained.signal()
                    }
                }
            )
        }

        release.finish()
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
        store.schedulingGenerations.enableDeterministicTime(owner: store)
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
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let cap = Capability.custom("deterministicGen_\(UUID().uuidString)")

        let done = AsyncGate()
        let completions = Probe()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0),
            task: {},
            completion: { _ in
                Task {
                    await completions.inc()
                    done.signal()
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
                    done.signal()
                }
            }
        )
        #expect(store.pendingTaskCount == 2)

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 2)
        await store.schedulingGenerations.advanceTime(by: 5.0)
        for await _ in done.stream {
            if await completions.count == 2 { break }
        }

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.generationCount == 1)
    }
}
