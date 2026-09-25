import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

@Suite("Configuration Tests")
struct ConfigurationTests {
    @Test("defaultTimeout varies expiry for default-timed tasks")
    func defaultTimeoutVariesExpiry() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 0.2),
            deterministic: true,
            prefix: "ConfigTimeout"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask])
        ) {
            started.signal()
            await release.wait()
            return "should-expire"
        }

        await started.wait()
        await store.advanceTime(by: 0.2)
        release.finish()

        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
    }

    @Test("explicit 30.0 timeout is honored, not treated as default")
    func explicitDefaultValueHonored() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ConfigExplicit30")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.2, maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let result: String? = await scheduler.scheduleAndWait(task) {
            return "ok"
        }

        #expect(result == "ok")
    }

    @Test("explicit timeout wins over defaultTimeout")
    func explicitTimeoutWins() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ConfigExplicit")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.2, maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result: String? = await scheduler.scheduleAndWait(task) {
            "ok"
        }

        #expect(result == "ok")
    }

    @Test("custom limits still drain via public counts")
    func customLimitsDrain() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ConfigLimits")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 2)
        )

        let total = 6
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
                        scheduler.schedule(task, taskExecution: {}, completion: { _ in done.resume() })
                    }
                }
            }
        }

        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("store configuration varies default timeout")
    func storeConfigurationVariesTimeout() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 0.2),
            deterministic: true,
            prefix: "ConfigStore"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask])
        ) {
            started.signal()
            await release.wait()
            return "should-expire"
        }

        await started.wait()
        await store.advanceTime(by: 0.2)
        release.finish()

        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("store configureScheduler preserves generations while varying limits")
    func storeConfigureVariesLimits() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ConfigStoreLimits")
        defer { store.unregisterCapability(for: pluginId) }
        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 2))

        let total = 4
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        store.scheduleTask(
                            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0),
                            task: {},
                            completion: { _ in done.resume() }
                        )
                    }
                }
            }
        }

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("bridge unspecified timeout follows scheduler default")
    func bridgeUnspecifiedFollowsDefault() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 0.2),
            deterministic: true,
            prefix: "ConfigBridgeUnspec"
        )
        defer { store.unregisterCapability(for: pluginId) }
        let bridge = ObjcStoreBridge(store: store)

        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)
        #expect(!descriptor.hasExplicitTimeout)

        let started = AsyncGate()
        let gate = DispatchSemaphore(value: 0)
        await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(descriptor, task: {
                started.signal()
                gate.wait()
                return NSString(string: "should-expire")
            }, completion: { result in
                #expect(result == nil)
                continuation.resume()
            })
            Task {
                await started.wait()
                await store.advanceTime(by: 0.2)
                gate.signal()
            }
        }
        #expect(store.pendingTaskCount == 0)
    }

    @Test("bridge explicit timeout honored over scheduler default")
    func bridgeExplicitHonored() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 0.2),
            prefix: "ConfigBridgeExplicit"
        )
        defer { store.unregisterCapability(for: pluginId) }
        let bridge = ObjcStoreBridge(store: store)

        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 30.0)
        #expect(descriptor.hasExplicitTimeout)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(descriptor, task: {
                NSString(string: "ok")
            }, completion: { result in
                #expect((result as? String) == "ok")
                continuation.resume()
            })
        }
    }
}
