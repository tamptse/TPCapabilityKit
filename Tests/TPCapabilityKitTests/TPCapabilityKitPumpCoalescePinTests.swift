import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Pump Coalesce Pins")
struct PumpCoalescePinTests {
    @Test("burst drains to zero with every completion delivered exactly once")
    func burstDrainsToZeroExactlyOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "PumpBurst")
        defer { store.unregisterCapability(for: pluginId) }

        let total = 50
        let completions = Probe()
        let drained = AsyncGate()
        for _ in 0..<total {
            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
                task: {},
                completion: { _ in
                    Task {
                        await completions.inc()
                        drained.signal()
                    }
                }
            )
        }

        for await _ in drained.stream {
            if await completions.count == total { break }
        }
        drained.finish()

        #expect(await completions.count == total)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("burst preserves priority high-before-low")
    func burstPreservesPriorityOrder() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 10, maxGlobal: 1),
            prefix: "PumpPriority"
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
        drained.finish()

        #expect(await order.values == ["high", "low"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("slot limits serialize activation under burst")
    func slotLimitsSerializeUnderBurst() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 1),
            prefix: "PumpSlot"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let probe = Probe()
        let completions = Probe()
        let drained = AsyncGate()
        let total = 10
        for _ in 0..<total {
            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
                task: {
                    await probe.enter()
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

        for await _ in drained.stream {
            if await completions.count == total { break }
        }
        drained.finish()

        #expect(await probe.maxSeen == 1)
        #expect(await completions.count == total)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("parked rows wake to activation on capability arrival")
    func parkedRowsWakeOnCapabilityArrival() async {
        let store = DynamicStore()
        let cap = Capability.custom("pumpWake_\(UUID().uuidString)")
        let pluginId = "PumpWake_\(UUID().uuidString)"

        let completions = Probe()
        let drained = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in
                Task {
                    await completions.inc()
                    drained.signal()
                }
            }
        )

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        for await _ in drained.stream {
            if await completions.count == 1 { break }
        }
        drained.finish()

        #expect(await completions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("retry re-queue rejoins the shared drain")
    func retryRequeueRejoinsSharedDrain() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "PumpRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct Boom: Error {}
        let result: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0, maxRetries: 1)
        ) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Boom() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel while queued lands terminal exactly once")
    func cancelWhileQueuedLandsTerminalOnce() async {
        let store = DynamicStore()
        let cap = Capability.custom("pumpCancelQ_\(UUID().uuidString)")

        let counter = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let lease = await withCheckedContinuation { (resumed: CheckedContinuation<Lease, Never>) in
            store.scheduleTask(
                descriptor,
                task: {},
                completion: { finished in
                    Task {
                        await counter.inc()
                        done.signal()
                        resumed.resume(returning: finished)
                    }
                }
            )
            store.cancelTask(taskId: descriptor.id)
        }

        await done.wait()
        #expect(lease.isTerminal)
        #expect(await counter.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel while parked lands terminal exactly once")
    func cancelWhileParkedLandsTerminalOnce() async {
        let store = DynamicStore()
        let cap = Capability.custom("pumpCancelP_\(UUID().uuidString)")

        let counter = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let lease = await withCheckedContinuation { (resumed: CheckedContinuation<Lease, Never>) in
            store.scheduleTask(
                descriptor,
                task: {},
                completion: { finished in
                    Task {
                        await counter.inc()
                        done.signal()
                        resumed.resume(returning: finished)
                    }
                }
            )
            Task {
                while store.pendingTaskCount == 0 { await Task.yield() }
                store.cancelTask(taskId: descriptor.id)
            }
        }

        await done.wait()
        #expect(lease.isTerminal)
        #expect(await counter.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel while active lands terminal exactly once")
    func cancelWhileActiveLandsTerminalOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "PumpCancelActive")
        defer { store.unregisterCapability(for: pluginId) }

        let counter = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = await withCheckedContinuation { (resumed: CheckedContinuation<Lease, Never>) in
            store.scheduleTask(task, task: {
                started.signal()
                await release.wait()
            }, completion: { finished in
                Task {
                    await counter.inc()
                    done.signal()
                    resumed.resume(returning: finished)
                }
            })
            Task {
                await started.wait()
                store.cancelTask(taskId: task.id)
                release.finish()
            }
        }

        await done.wait()
        #expect(lease.isTerminal)
        #expect(await counter.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("no entry spawns a raw drain; all kicks share one pump")
    func noRawDrainSpawnRemains() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let root = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schedulerURL = root.appendingPathComponent("Sources/TPCapabilityKit/TaskScheduler.swift")
        let pathURL = root.appendingPathComponent("Sources/TPCapabilityKit/TaskScheduler+Path.swift")
        let scheduler = try String(contentsOf: schedulerURL, encoding: .utf8)
        let path = try String(contentsOf: pathURL, encoding: .utf8)
        for source in [scheduler, path] {
            #expect(!source.contains("processPendingTasks"))
        }
        #expect(scheduler.contains("func kickPump()"))
        #expect(path.contains("func guardedDrain()"))
    }
}
