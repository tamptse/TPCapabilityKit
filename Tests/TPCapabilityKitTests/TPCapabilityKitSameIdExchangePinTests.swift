import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Same-ID Exchange Pins")
struct SameIdExchangePinTests {
    @Test("concurrent same-id overwrite expires old exactly once and new completes")
    func concurrentOverwriteExpiresOldOnce() async {
        let store = DynamicStore()
        let cap = Capability.custom("r6-overwrite_\(UUID().uuidString)")
        let id = "r6-overwrite_\(UUID().uuidString)"
        let pluginId = "r6-overwrite_\(UUID().uuidString)"

        let total = 8
        actor State {
            var expired = 0
            var completed = 0
            var totalCalls = 0
            func record(_ lease: Lease) {
                totalCalls += 1
                switch lease.state {
                case .expired: expired += 1
                case .completed: completed += 1
                default: break
                }
            }
        }
        let state = State()
        let drained = AsyncGate()

        let leases = await withTaskGroup(of: Lease.self, returning: [Lease].self) { group in
            for _ in 0..<total {
                group.addTask {
                    store.scheduleTask(
                        TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0),
                        task: {},
                        completion: { finished in
                            Task {
                                await state.record(finished)
                                drained.signal()
                            }
                        }
                    )
                }
            }
            var out: [Lease] = []
            for await lease in group {
                out.append(lease)
            }
            return out
        }
        #expect(leases.count == total)

        for await _ in drained.stream {
            if await state.totalCalls == total - 1 { break }
        }
        #expect(await state.expired == total - 1)
        #expect(await state.completed == 0)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        for await _ in drained.stream {
            if await state.totalCalls == total { break }
        }

        #expect(await state.totalCalls == total)
        #expect(await state.expired == total - 1)
        #expect(await state.completed == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("overwrite with slot contention keeps new waiter while stale resume lands terminal")
    func overwriteSlotContentionKeepsNew() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1),
            prefix: "r6slot"
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

        let id = "r6-slot_\(UUID().uuidString)"
        let executions = Probe()
        actor Completions {
            var oldCalls = 0
            var oldState: Lease.State?
            var newCalls = 0
            var newState: Lease.State?
            func recordOld(_ lease: Lease) {
                oldCalls += 1
                oldState = lease.state
            }
            func recordNew(_ lease: Lease) {
                newCalls += 1
                newState = lease.state
            }
        }
        let completions = Completions()
        let oldDone = AsyncGate()
        let newDone = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await executions.append("old") },
            completion: { finished in
                Task {
                    await completions.recordOld(finished)
                    oldDone.signal()
                }
            }
        )
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let newLease = store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await executions.append("new") },
            completion: { finished in
                Task {
                    await completions.recordNew(finished)
                    newDone.signal()
                }
            }
        )

        await oldDone.wait()
        #expect(await completions.oldCalls == 1)
        #expect(await completions.oldState == .expired)
        #expect(!newLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        release.finish()
        await newDone.wait()
        await holderDone.wait()

        #expect(await completions.newCalls == 1)
        #expect(await completions.newState == .completed)
        #expect(await executions.values.filter { $0 == "old" }.isEmpty)
        #expect(await executions.values.filter { $0 == "new" }.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel after overwrite lands on new row only with no absence")
    func cancelAfterOverwriteLandsOnNew() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("r6-cancel_\(UUID().uuidString)")
        let id = "r6-cancel_\(UUID().uuidString)"

        let oldProbe = Probe()
        let oldDone = AsyncGate()
        let old = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let oldLease = store.scheduleTask(old, task: {}, completion: { finished in
            Task {
                await oldProbe.record(finished)
                oldDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(store.pendingTaskCount == 1)
        #expect(!oldLease.isTerminal)

        let newProbe = Probe()
        let newDone = AsyncGate()
        let new = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let newLease = store.scheduleTask(new, task: {}, completion: { finished in
            Task {
                await newProbe.record(finished)
                newDone.signal()
            }
        })

        await oldDone.wait()
        #expect(oldLease.state == .expired)
        #expect(await oldProbe.count == 1)
        #expect(await oldProbe.states == [.expired])
        #expect(!newLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: id)
        await newDone.wait()

        #expect(newLease.state == .expired)
        #expect(await newProbe.count == 1)
        #expect(await newProbe.states == [.expired])
        #expect(await oldProbe.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let reuseProbe = Probe()
        let reuseDone = AsyncGate()
        let reuse = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let reuseLease = store.scheduleTask(reuse, task: {}, completion: { finished in
            Task {
                await reuseProbe.record(finished)
                reuseDone.signal()
            }
        })
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!reuseLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: id)
        await reuseDone.wait()
        #expect(reuseLease.state == .expired)
        #expect(await reuseProbe.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel before overwrite then reschedule works after terminal")
    func cancelBeforeOverwriteThenReschedule() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("r6-cancelbefore_\(UUID().uuidString)")
        let id = "r6-cancelbefore_\(UUID().uuidString)"

        let firstProbe = Probe()
        let firstDone = AsyncGate()
        let first = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let firstLease = store.scheduleTask(first, task: {}, completion: { finished in
            Task {
                await firstProbe.record(finished)
                firstDone.signal()
            }
        })
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        store.cancelTask(taskId: id)
        await firstDone.wait()
        #expect(firstLease.state == .expired)
        #expect(await firstProbe.count == 1)
        #expect(store.pendingTaskCount == 0)

        let secondProbe = Probe()
        let secondDone = AsyncGate()
        let second = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let secondLease = store.scheduleTask(second, task: {}, completion: { finished in
            Task {
                await secondProbe.record(finished)
                secondDone.signal()
            }
        })
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!secondLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: id)
        await secondDone.wait()
        #expect(secondLease.state == .expired)
        #expect(await secondProbe.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("concurrent schedule-wait storm resolves exactly once without joining new lease")
    func scheduleWaitGuardNeverJoinsNewLease() async {
        let store = DynamicStore()
        let cap = Capability.custom("r6-waitguard_\(UUID().uuidString)")
        let id = "r6-waitguard_\(UUID().uuidString)"
        let pluginId = "r6-waitguard_\(UUID().uuidString)"
        let total = 5

        await withTaskGroup(of: String?.self) { group in
            for index in 0..<total {
                group.addTask {
                    await store.scheduleTaskAndWait(
                        TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0)
                    ) { () async throws -> String in
                        return "value-\(index)"
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            store.registerCapability(for: pluginId, capabilities: [cap])
            var results: [String?] = []
            for await result in group {
                results.append(result)
            }
            let hits = results.compactMap { $0 }
            #expect(results.count == total)
            #expect(hits.count == 1)
            #expect(hits.first?.hasPrefix("value-") == true)
            #expect(store.pendingTaskCount == 0)
            #expect(store.activeTaskCount == 0)
        }
        store.unregisterCapability(for: pluginId)
    }

    @Test("displaced parked waiter cancelled once and never runs after caps arrive")
    func displacedParkWaiterCancelledOnce() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("r6-park_\(UUID().uuidString)")
        let id = "r6-park_\(UUID().uuidString)"
        let pluginId = "r6-park_\(UUID().uuidString)"

        let executions = Probe()
        let oldProbe = Probe()
        let oldDone = AsyncGate()
        let old = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let oldLease = store.scheduleTask(old, task: {
            await executions.append("old")
        }, completion: { finished in
            Task {
                await oldProbe.record(finished)
                oldDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!oldLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        let newProbe = Probe()
        let newDone = AsyncGate()
        let new = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let newLease = store.scheduleTask(new, task: {
            await executions.append("new")
        }, completion: { finished in
            Task {
                await newProbe.record(finished)
                newDone.signal()
            }
        })

        await oldDone.wait()
        #expect(oldLease.state == .expired)
        #expect(await oldProbe.count == 1)
        #expect(!newLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [missing])
        defer { store.unregisterCapability(for: pluginId) }
        await newDone.wait()

        #expect(newLease.state == .completed)
        #expect(await newProbe.count == 1)
        #expect(await oldProbe.count == 1)
        #expect(await executions.values.filter { $0 == "old" }.isEmpty)
        #expect(await executions.values.filter { $0 == "new" }.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("retry identity and waiter preservation unchanged")
    func retryIdentityPreserved() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "r6retry")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct Flaky: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Flaky() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
