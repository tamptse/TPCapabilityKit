import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("D6 Settlement Decision Table")
struct D6DecisionTableTests {
    @Test("won with value completes")
    func wonWithValueCompletes() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6Value")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result = await store.scheduleTaskAndWait(task) { "d6-value" }

        #expect(result == "d6-value")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("void schedule completes with waiter delivered")
    func voidScheduleCompletes() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6Void")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let state = Probe()
        let done = AsyncGate()
        let returned = scheduler.schedule(task, taskExecution: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })
        await done.wait()

        #expect(await state.count == 1)
        #expect(await state.lastState == .completed)
        #expect(await state.lastLease === returned)
        #expect(returned.state == .completed)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("won stored-nil with budget retries and recovers")
    func storedNilWithBudgetRetriesAndRecovers() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6NilRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let attempts = Probe()
        struct D6Flaky: Error {}
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw D6Flaky() }
            return "d6-recovered"
        }

        #expect(result == "d6-recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("won stored-nil without budget delivers nil exactly once")
    func storedNilWithoutBudgetDeliversNilOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6NilNoBudget")
        defer { store.unregisterCapability(for: pluginId) }

        struct D6Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let attempts = Probe()
        let result: String? = await store.scheduleTaskAndWait(task) { () async throws -> String in
            await attempts.next()
            throw D6Boom()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("timeout empty expires despite retry budget")
    func timeoutEmptyExpiresDespiteBudget() async {
        let cap = Capability.custom("D6Timeout_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], deterministic: true, prefix: "D6Timeout")
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let deliveries = Probe()
        let attempts = Probe()
        let task = TaskDescriptor(requiredCapabilities: [cap], timeout: 0.2, maxRetries: 1)
        let lease = store.scheduleTask(task, task: {
            await attempts.inc()
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                done.signal()
            }
        })
        await started.wait()
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        await store.schedulingGenerations.advanceTime(by: 0.2)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(await attempts.count == 1)
        #expect(await deliveries.count == 1)
        #expect(await deliveries.lastState == .expired)

        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(lease.state == .expired)
        #expect(await attempts.count == 1)
        #expect(await deliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel of active lands expired exactly once")
    func cancelActiveLandsExpired() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6CancelActive")
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let state = Probe()
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = store.scheduleTask(descriptor, task: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        await started.wait()
        store.cancelTask(taskId: descriptor.id)
        await done.wait()
        release.finish()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(await state.count == 1)
        #expect(await state.lastState == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel of pending lands expired exactly once")
    func cancelPendingLandsExpired() async {
        let store = DynamicStore()
        let missing = Capability.custom("D6CancelPending_\(UUID().uuidString)")
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)

        let state = Probe()
        let done = AsyncGate()
        let lease = store.scheduleTask(descriptor, task: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })
        store.cancelTask(taskId: descriptor.id)
        await done.wait()

        #expect(await state.count == 1)
        #expect(await state.lastState == .expired)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("failed when active terminalizes failed exactly once")
    func failedWhenActiveTerminalizesFailed() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6FailedActive")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let state = Probe()
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        await started.wait()
        #expect(lease.state == .active)
        scheduler.settle(lease, as: .failed)
        await done.wait()

        #expect(await state.count == 1)
        if case .failed = await state.lastState { } else { Issue.record("expected failed") }
        if case .failed = lease.state { } else { Issue.record("expected failed") }
        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(await state.count == 1)
        if case .failed = lease.state { } else { Issue.record("expected failed") }
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("stored-nil without budget when active fails")
    func storedNilWithoutBudgetWhenActiveFails() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6NilActive")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let state = Probe()
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0, maxRetries: 0)
        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        await started.wait()
        scheduler.settle(lease, as: .completed(nil))
        await done.wait()

        #expect(await state.count == 1)
        if case .failed = lease.state { } else { Issue.record("expected failed") }
        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(await state.count == 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("failed when pending expires")
    func failedWhenPendingExpires() async {
        let store = DynamicStore()
        let missing = Capability.custom("D6FailedPending_\(UUID().uuidString)")
        let scheduler = makeScheduler(store: store)

        let state = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)
        let lease = scheduler.schedule(descriptor, taskExecution: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })
        scheduler.settle(lease, as: .failed)
        await done.wait()

        #expect(await state.count == 1)
        #expect(await state.lastState == .expired)
        #expect(lease.state == .expired)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("completed-nil without budget when pending expires")
    func completedNilWithoutBudgetWhenPendingExpires() async {
        let store = DynamicStore()
        let missing = Capability.custom("D6NilPending_\(UUID().uuidString)")
        let scheduler = makeScheduler(store: store)

        let state = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0, maxRetries: 0)
        let lease = scheduler.schedule(descriptor, taskExecution: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })
        scheduler.settle(lease, as: .completed(nil))
        await done.wait()

        #expect(await state.count == 1)
        #expect(await state.lastState == .expired)
        #expect(lease.state == .expired)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("completed when pending refuses completion")
    func completedWhenPendingRefusesCompletion() async {
        let store = DynamicStore()
        let missing = Capability.custom("D6CompletedPending_\(UUID().uuidString)")
        let scheduler = makeScheduler(store: store)

        let state = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)
        let lease = scheduler.schedule(descriptor, taskExecution: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })
        scheduler.settle(lease, as: .completed("d6-value"))
        await done.wait()

        #expect(await state.count == 1)
        #expect(lease.state == .pending)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("cancelled when active lands expired")
    func cancelledWhenActiveLandsExpired() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6CancelledActive")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let state = Probe()
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        await started.wait()
        scheduler.settle(lease, as: .cancelled)
        await done.wait()

        #expect(await state.count == 1)
        #expect(await state.lastState == .expired)
        #expect(lease.state == .expired)
        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(await state.count == 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("retry reuses same identity, preserves waiter, and re-pumps")
    func retryReusesIdentityPreservesWaiterAndRepumps() async {
        let store = DynamicStore()
        let pluginId = "D6RetryIdentity_\(UUID().uuidString)"
        let missing = Capability.custom("D6RetryIdentity_\(UUID().uuidString)")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let done = AsyncGate()
        let state = Probe()
        let attempts = Probe()
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0, maxRetries: 1)
        let lease = scheduler.schedule(descriptor, taskExecution: {
            await attempts.inc()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        scheduler.settle(lease, as: .completed(nil))

        #expect(lease.retryCount == 1)
        #expect(lease.state == .pending)
        #expect(await state.count == 0)
        store.registerCapability(for: pluginId, capabilities: [missing])
        await done.wait()

        #expect(await attempts.count == 1)
        #expect(await state.count == 1)
        #expect(await state.lastState == .completed)
        #expect(await state.lastLease === lease)
        #expect(lease.state == .completed)
        for _ in 0..<50 { await Task.yield() }

        #expect(await state.count == 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("terminal rejects a second settle without redelivery")
    func terminalRejectsSecondSettle() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D6SecondSettle")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let state = Probe()
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        await started.wait()
        scheduler.settle(lease, as: .completed("d6-value"))
        await done.wait()
        scheduler.settle(lease, as: .failed)
        for _ in 0..<50 { await Task.yield() }

        #expect(await state.count == 1)
        #expect(await state.lastState == .completed)
        #expect(lease.state == .completed)
        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(await state.count == 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("slot stays held until activation scope exits")
    func slotHeldUntilScopeExit() async {
        let config = TaskScheduler.Configuration(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 1)
        let (store, pluginId) = makeStoreWithCap([.heavyTask], configuration: config, prefix: "D6Slot")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store, configuration: config)

        let startedFirst = AsyncGate()
        let release = AsyncGate()
        let doneFirst = AsyncGate()
        let doneSecond = AsyncGate()
        let firstState = Probe()
        let secondState = Probe()
        let secondAttempts = Probe()
        let first = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let second = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let firstLease = scheduler.schedule(first, taskExecution: {
            startedFirst.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await firstState.record(finished)
                doneFirst.signal()
            }
        })
        let secondLease = scheduler.schedule(second, taskExecution: {
            await secondAttempts.inc()
        }, completion: { finished in
            Task {
                await secondState.record(finished)
                doneSecond.signal()
            }
        })

        await startedFirst.wait()
        for _ in 0..<200 { await Task.yield() }
        scheduler.settle(firstLease, as: .failed)
        await doneFirst.wait()
        for _ in 0..<200 { await Task.yield() }

        #expect(await secondAttempts.count == 0)
        #expect(await secondState.count == 0)
        release.finish()
        await doneSecond.wait()

        #expect(await secondAttempts.count == 1)
        #expect(await secondState.count == 1)
        #expect(await secondState.lastState == .completed)
        #expect(secondLease.state == .completed)
        if case .failed = firstLease.state { } else { Issue.record("expected failed") }
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}
