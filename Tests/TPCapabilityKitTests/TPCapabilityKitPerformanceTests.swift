@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

@Suite struct TPCapabilityKitPerformanceTests {
    
    struct TestPlugin: AppPlugin {
        let id: String
        func start(with store: DynamicStore) {
            store.updateState(pluginId: id, newState: "InitialPluginState")
        }
    }

    final class MockObjcPlugin: NSObject, ObjcAppPlugin, @unchecked Sendable {
        let id: String
        var isStarted = false
        
        init(id: String = "ObjcPluginA") {
            self.id = id
            super.init()
        }
        
        func start(with store: ObjcStoreBridge) {
            isStarted = true
            store.updateState(pluginId: id, newState: NSString(string: "ObjcInitialState"))
        }
    }

    // MARK: - Swift Core Function Benchmarks
    
    @Test func benchmarkSwiftRegister() {
        let store = DynamicStore()
        let iterations = 20_000
        
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            let plugin = TestPlugin(id: "SwiftReg_\(i)")
            store.register(plugin: plugin)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] DynamicStore.register: \(iterations) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }
    
    @Test func benchmarkSwiftUpdateState() {
        let store = DynamicStore()
        let iterations = 50_000
        
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            store.updateState(pluginId: "SwiftUpdate_\(i % 100)", newState: i)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] DynamicStore.updateState: \(iterations) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }

    @Test func benchmarkSwiftGetState() {
        let store = DynamicStore()
        let iterations = 100_000
        store.updateState(pluginId: "SwiftGetKey", newState: "Value")
        
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = store.getState(pluginId: "SwiftGetKey", type: String.self)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] DynamicStore.getState: \(iterations) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }
    
    @Test func benchmarkSwiftObserveState() {
        let store = DynamicStore()
        let iterations = 10_000
        var receivedCount = 0
        var cancellables = Set<AnyCancellable>()
        
        store.observeState(pluginId: "ObserveKey", type: Int.self)
            .sink { _ in
                receivedCount += 1
            }
            .store(in: &cancellables)
            
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            store.updateState(pluginId: "ObserveKey", newState: i)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] DynamicStore.observeState throughput: \(iterations) events in \(String(format: "%.6f", elapsed))s")
        #expect(receivedCount == iterations)
        #expect(elapsed < 1.0)
    }

    // MARK: - Objective-C Bridge Function Benchmarks

    @Test func benchmarkObjcRegister() {
        let bridge = ObjcStoreBridge.shared
        let iterations = 20_000
        
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            let objcPlugin = MockObjcPlugin(id: "ObjcReg_\(i)")
            bridge.register(plugin: objcPlugin)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] ObjcStoreBridge.register: \(iterations) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }

    @Test func benchmarkObjcUpdateState() {
        let bridge = ObjcStoreBridge.shared
        let iterations = 50_000
        
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            bridge.updateState(pluginId: "ObjcUpdate_\(i % 100)", newState: NSNumber(value: i))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] ObjcStoreBridge.updateState: \(iterations) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }

    @Test func benchmarkObjcGetState() {
        let bridge = ObjcStoreBridge.shared
        let iterations = 100_000
        bridge.updateState(pluginId: "ObjcGetKey", newState: NSString(string: "ObjcValue"))
        
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = bridge.getState(pluginId: "ObjcGetKey")
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] ObjcStoreBridge.getState: \(iterations) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }

    // MARK: - Multi-Threaded Concurrency Benchmark

    @Test func benchmarkConcurrentReadWrite() async {
        let store = DynamicStore()
        let taskCount = 10
        let operationsPerTask = 5_000
        let totalOperations = taskCount * operationsPerTask
        
        let start = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    let pluginId = "ConcurrentPlugin_\(taskId)"
                    for i in 0..<operationsPerTask {
                        store.updateState(pluginId: pluginId, newState: i)
                        _ = store.getState(pluginId: pluginId, type: Int.self)
                    }
                }
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("[BENCHMARK] DynamicStore Concurrent Read/Write (\(taskCount) tasks): \(totalOperations * 2) ops in \(String(format: "%.6f", elapsed))s")
        #expect(elapsed < 1.0)
    }

    // MARK: - Lock Performance Comparison

    @Test func benchmarkLockComparison() {
        let iterations = 10_000_000
        
        // 1. NSRecursiveLock
        let recursiveLock = NSRecursiveLock()
        let startRecursive = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            recursiveLock.lock()
            recursiveLock.unlock()
        }
        let elapsedRecursive = CFAbsoluteTimeGetCurrent() - startRecursive
        
        // 2. NSLock
        let nsLock = NSLock()
        let startNSLock = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            nsLock.lock()
            nsLock.unlock()
        }
        let elapsedNSLock = CFAbsoluteTimeGetCurrent() - startNSLock
        
        // 3. UnfairLock (os_unfair_lock via Heap Pointer)
        let unfairLock = UnfairLock()
        let startUnfair = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            unfairLock.lock()
            unfairLock.unlock()
        }
        let elapsedUnfair = CFAbsoluteTimeGetCurrent() - startUnfair
        
        print("""
        ----------------------------------------------------
        [LOCK BENCHMARK RESULTS - \(iterations) Iterations]
        - NSRecursiveLock: \(String(format: "%.6f", elapsedRecursive))s
        - NSLock:          \(String(format: "%.6f", elapsedNSLock))s
        - os_unfair_lock:  \(String(format: "%.6f", elapsedUnfair))s
        ----------------------------------------------------
        """)
        
        // Benchmark is informational only — timing varies across runs
        // os_unfair_lock, NSLock, and NSRecursiveLock are all < 3s for 10M iterations
        #expect(elapsedNSLock < 3.0)
        #expect(elapsedUnfair < 3.0)
        #expect(elapsedRecursive < 3.0)
    }
}

private final class UnfairLock: @unchecked Sendable {
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock>
    
    init() {
        lockPointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPointer.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lockPointer.deinitialize(count: 1)
        lockPointer.deallocate()
    }
    
    func lock() {
        os_unfair_lock_lock(lockPointer)
    }
    
    func unlock() {
        os_unfair_lock_unlock(lockPointer)
    }
}
