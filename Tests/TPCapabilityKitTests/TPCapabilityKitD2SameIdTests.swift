import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("D2 Same-ID Exchange Pins")
struct D2SameIdExchangePinTests {
    @Test("overwrite across both entries expires old once while new completes")
    func overwriteAcrossBothEntries() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1),
            prefix: "d2overwrite"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let holderDone = AsyncGate()
        let holder = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in holderDone.signal() })
        await started.wait()
        #expect(store.activeTaskCount == 1)

        let id = "d2-overwrite_\(UUID().uuidString)"
        let executions = Probe()
        let oldProbe = Probe()
        let oldDone = AsyncGate()
        let oldLease = store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await executions.append("old") },
            completion: { finished in
                Task {
                    await oldProbe.record(finished)
                    oldDone.signal()
                }
            }
        )
        #expect(!oldLease.isTerminal)

        let waiter = Task {
            await store.scheduleTaskAndWait(
                TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 10.0)
            ) { () async throws -> String in
                await executions.append("new")
                return "new-value"
            }
        }

        await oldDone.wait()
        #expect(oldLease.state == .expired)
        #expect(await oldProbe.count == 1)
        #expect(await oldProbe.states == [.expired])
        #expect(store.pendingTaskCount == 1)

        release.finish()
        let value = await waiter.value
        await holderDone.wait()

        #expect(value == "new-value")
        #expect(await oldProbe.count == 1)
        #expect(await executions.values.filter { $0 == "old" }.isEmpty)
        #expect(await executions.values.filter { $0 == "new" }.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel during overwrite resolves once with reuse and wait-cancel nil")
    func cancelDuringOverwrite() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let missing = Capability.custom("d2-cancel_\(UUID().uuidString)")
        let id = "d2-cancel_\(UUID().uuidString)"

        let oldProbe = Probe()
        let oldDone = AsyncGate()
        let oldLease = store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { finished in
                Task {
                    await oldProbe.record(finished)
                    oldDone.signal()
                }
            }
        )
        await store.waitForDeterministicWaiters(count: 1)

        let newProbe = Probe()
        let newDone = AsyncGate()
        let newLease = store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { finished in
                Task {
                    await newProbe.record(finished)
                    newDone.signal()
                }
            }
        )

        await oldDone.wait()
        #expect(oldLease.state == .expired)
        #expect(await oldProbe.count == 1)
        #expect(!newLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: id)
        await newDone.wait()
        #expect(newLease.state == .expired)
        #expect(await newProbe.count == 1)
        #expect(await oldProbe.count == 1)
        #expect(store.pendingTaskCount == 0)

        let waiter = Task {
            await store.scheduleTaskAndWait(
                TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
            ) { () async throws -> String in "reused" }
        }
        await store.waitForDeterministicWaiters(count: 1)
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: id)
        #expect(await waiter.value == nil)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("waiter guard across both entries with retry and plain enqueue intact")
    func waiterGuardAcrossBothEntries() async {
        let store = DynamicStore()
        let cap = Capability.custom("d2-guard_\(UUID().uuidString)")
        let id = "d2-guard_\(UUID().uuidString)"
        let pluginId = "d2-guard_\(UUID().uuidString)"
        let total = 4

        actor Completions {
            var expired = 0
            var completed = 0
            func record(_ lease: Lease) {
                switch lease.state {
                case .expired: expired += 1
                case .completed: completed += 1
                default: break
                }
            }
        }
        let completions = Completions()

        let deliveredValues = await withTaskGroup(of: String?.self) { group in
            for index in 0..<total {
                if index % 2 == 0 {
                    group.addTask {
                        await store.scheduleTaskAndWait(
                            TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0)
                        ) { () async throws -> String in "value-\(index)" }
                    }
                } else {
                    group.addTask {
                        let gate = AsyncGate()
                        store.scheduleTask(
                            TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0),
                            task: {},
                            completion: { finished in
                                Task {
                                    await completions.record(finished)
                                    gate.signal()
                                }
                            }
                        )
                        await gate.wait()
                        return nil
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            store.registerCapability(for: pluginId, capabilities: [cap])
            var results: [String?] = []
            for await result in group {
                results.append(result)
            }
            #expect(results.count == total)
            #expect(store.pendingTaskCount == 0)
            #expect(store.activeTaskCount == 0)
            return results.compactMap { $0 }.count
        }
        store.unregisterCapability(for: pluginId)
        let expired = await completions.expired
        let completed = await completions.completed
        #expect(deliveredValues <= 1)
        #expect((deliveredValues == 1) == (completed == 0))
        #expect(expired == total / 2 - 1 || expired == total / 2)
        #expect(expired + completed == total / 2)

        let (retryStore, retryPlugin) = makeStoreWithCap([.heavyTask], prefix: "d2retry")
        defer { retryStore.unregisterCapability(for: retryPlugin) }
        let attempts = Probe()
        struct Flaky: Error {}
        let recovered = await retryStore.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        ) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Flaky() }
            return "recovered"
        }
        #expect(recovered == "recovered")
        #expect(await attempts.count == 2)
        #expect(retryStore.pendingTaskCount == 0)
        #expect(retryStore.activeTaskCount == 0)
    }
}
