import Testing
import Foundation
@testable import TPCapabilityKit

private func neverClock() -> TaskScheduler.ExpiryClock {
    let gate = AsyncStream<Void>.makeStream()
    return TaskScheduler.ExpiryClock(
        sleep: { _ in
            for await _ in gate.stream { break }
        }
    )
}

private func immediateClock() -> TaskScheduler.ExpiryClock {
    TaskScheduler.ExpiryClock(sleep: { _ in })
}

@Suite("Deadline Tests")
struct DeadlineTests {
    @Test("resolve pins nil timeout to the configured default")
    func resolvePinsNilToDefault() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        #expect(task.timeout == nil)
        #expect(TaskScheduler.Deadline.resolve(task: task, default: 0.3) == 0.3)
    }

    @Test("resolve carries an explicit timeout unchanged")
    func resolveCarriesExplicitTimeout() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 7.5)
        #expect(TaskScheduler.Deadline.resolve(task: task, default: 0.3) == 7.5)
    }

    @Test("race favours the operation when the clock never fires")
    func raceFavoursOperation() async {
        let recording = TaskScheduler.DeadlineRecording()
        let deadline = TaskScheduler.Deadline(timeout: 0.5, clock: neverClock(), recording: recording)

        let won = await deadline.race(.execution) { true }

        #expect(won == true)
        #expect(recording.all == [.init(race: .execution, outcome: .satisfied, timeout: 0.5)])
    }

    @Test("race expires when the operation never finishes")
    func raceExpiresWhenOperationPends() async {
        let recording = TaskScheduler.DeadlineRecording()
        let gate = AsyncStream<Void>.makeStream()
        let deadline = TaskScheduler.Deadline(timeout: 0.5, clock: immediateClock(), recording: recording)

        let won = await deadline.race(.wait) {
            for await _ in gate.stream { break }
            return true
        }

        #expect(won == false)
        #expect(recording.all == [.init(race: .wait, outcome: .expired, timeout: 0.5)])
        gate.continuation.finish()
    }

    @Test("wait expiry records the wait race through the scheduler")
    func waitExpiryRecordsWaitRace() async {
        let store = DynamicStore()
        let recording = TaskScheduler.DeadlineRecording()
        let scheduler = TaskScheduler(store: store, clock: immediateClock(), recording: recording)

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("DeadlineWait_\(UUID().uuidString)")],
            timeout: 0.3
        )
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.continuation.yield()
        })
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(recording.all == [.init(race: .wait, outcome: .expired, timeout: 0.3)])
    }

    @Test("execution expiry records the execution race through the scheduler")
    func executionExpiryRecordsExecutionRace() async {
        let store = DynamicStore()
        let pluginId = "DeadlineExec_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let recording = TaskScheduler.DeadlineRecording()
        let scheduler = TaskScheduler(store: store, clock: immediateClock(), recording: recording)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }, completion: { _ in
            done.continuation.yield()
        })
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(recording.all == [.init(race: .execution, outcome: .expired, timeout: 0.2)])
    }
}
